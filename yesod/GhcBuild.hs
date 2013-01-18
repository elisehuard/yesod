{-# OPTIONS_GHC -fno-warn-unused-do-bind #-}
{-# OPTIONS_GHC -fno-warn-unused-binds #-}
{-# OPTIONS_GHC -fno-warn-unused-imports #-}
{-# OPTIONS_GHC -fno-warn-unused-matches #-}
{-
  There is a lot of code copied from GHC here, and some conditional
  compilation. Instead of fixing all warnings and making it much more
  difficult to compare the code to the original, just ignore unused
  binds and imports.
-}
{-# LANGUAGE CPP                 #-}
{-# LANGUAGE PatternGuards       #-}
{-# LANGUAGE ScopedTypeVariables #-}

{-
  build package with the GHC API
-}

module GhcBuild (getBuildFlags, buildPackage) where

import qualified Control.Exception as Ex
import           Control.Monad     (when)
import           Data.IORef
import           System.Process    (rawSystem)
import           System.Environment (getEnvironment)

import           CmdLineParser
import           Data.Char         (toLower)
import           Data.List         (isPrefixOf, partition)
import           Data.Maybe        (fromMaybe)
import           DriverPhases      (Phase (..), anyHsc, isHaskellSrcFilename,
                                    isSourceFilename, startPhase)
import           DriverPipeline    (compileFile, link, linkBinary, oneShot)
import           DynFlags          (DynFlags, compilerInfo)
import qualified DynFlags
import qualified GHC
import           GHC.Paths         (libdir)
import           HscTypes          (HscEnv (..), emptyHomePackageTable)
import           MonadUtils        (liftIO)
import           Panic             (ghcError, panic)
import           SrcLoc            (Located, mkGeneralLocated)
import           StaticFlags       (v_Ld_inputs)
import qualified StaticFlags
import           System.FilePath   (normalise, (</>))
import           Util              (consIORef, looksLikeModuleName)

{-
  This contains a huge hack:
  GHC only accepts setting static flags once per process, however it has no way to
  get the remaining options from the command line, without setting the static flags.
  This code overwrites the IORef to disable the check. This will likely cause
  problems if the flags are modified, but fortunately that's relatively uncommon.
-}
getBuildFlags :: IO [Located String]
getBuildFlags = do
  argv0 <- fmap read $ readFile "yesod-devel/ghcargs.txt" -- generated by yesod-ghc-wrapper
  argv0' <- addHsenvArgs argv0
  let (minusB_args, argv1) = partition ("-B" `isPrefixOf`) argv0'
      mbMinusB | null minusB_args = Nothing
               | otherwise = Just (drop 2 (last minusB_args))
  let argv1' = map (mkGeneralLocated "on the commandline") argv1
  writeIORef StaticFlags.v_opt_C_ready False -- the huge hack
  (argv2, staticFlagWarnings) <- GHC.parseStaticFlags argv1'
  return argv2

addHsenvArgs :: [String] -> IO [String]
addHsenvArgs argv = do
  env <- getEnvironment
  return $ case (lookup "HSENV" env) of
             Nothing -> argv
             _       -> argv ++ hsenvArgv
                 where hsenvArgv = words $ fromMaybe "" (lookup "PACKAGE_DB_FOR_GHC" env)

buildPackage :: [Located String] -> FilePath -> FilePath -> IO Bool
buildPackage a ld ar = buildPackage' a ld ar `Ex.catch` \e -> do
  putStrLn ("exception building package: " ++ show (e :: Ex.SomeException))
  return False

buildPackage' :: [Located String] -> FilePath -> FilePath -> IO Bool
buildPackage' argv2 ld ar = do
  (mode, argv3, modeFlagWarnings) <- parseModeFlags argv2
  GHC.runGhc (Just libdir) $ do
    dflags0 <- GHC.getSessionDynFlags
    (dflags1, _, _) <- GHC.parseDynamicFlags dflags0 argv3
    let dflags2 = dflags1 { GHC.ghcMode   = GHC.CompManager
                          , GHC.hscTarget = GHC.hscTarget dflags1
                          , GHC.ghcLink   = GHC.LinkBinary
                          , GHC.verbosity = 1
                          }
    (dflags3, fileish_args, _) <- GHC.parseDynamicFlags dflags2 argv3
    GHC.setSessionDynFlags dflags3
    let normal_fileish_paths = map (normalise . GHC.unLoc) fileish_args
        (srcs, objs)         = partition_args normal_fileish_paths [] []
        (hs_srcs, non_hs_srcs) = partition haskellish srcs
        haskellish (f,Nothing) =
          looksLikeModuleName f || isHaskellSrcFilename f || '.' `notElem` f
        haskellish (_,Just phase) =
#if MIN_VERSION_ghc(7,4,0)
          phase `notElem` [As, Cc, Cobjc, Cobjcpp, CmmCpp, Cmm, StopLn]
#else
          phase `notElem` [As, Cc, CmmCpp, Cmm, StopLn]
#endif
    hsc_env <- GHC.getSession
--    if (null hs_srcs)
--       then liftIO (oneShot hsc_env StopLn srcs)
--       else do
#if MIN_VERSION_ghc(7,2,0)
    o_files <- mapM (\x -> liftIO $ compileFile hsc_env StopLn x)
#else
    o_files <- mapM (\x -> compileFile hsc_env StopLn x)
#endif
                 non_hs_srcs
    liftIO $ mapM_ (consIORef v_Ld_inputs) (reverse o_files)
    targets <- mapM (uncurry GHC.guessTarget) hs_srcs
    GHC.setTargets targets
    ok_flag <- GHC.load GHC.LoadAllTargets
    if GHC.failed ok_flag
      then return False
      else liftIO (linkPkg ld ar) >> return True

linkPkg :: FilePath -> FilePath -> IO ()
linkPkg ld ar = do
  arargs <- fmap read $ readFile "yesod-devel/arargs.txt"
  rawSystem ar arargs
  ldargs <- fmap read $ readFile "yesod-devel/ldargs.txt"
  rawSystem ld ldargs
  return ()

--------------------------------------------------------------------------------------------
-- stuff below copied from ghc main.hs
--------------------------------------------------------------------------------------------

partition_args :: [String] -> [(String, Maybe Phase)] -> [String]
               -> ([(String, Maybe Phase)], [String])
partition_args [] srcs objs = (reverse srcs, reverse objs)
partition_args ("-x":suff:args) srcs objs
  | "none" <- suff      = partition_args args srcs objs
  | StopLn <- phase     = partition_args args srcs (slurp ++ objs)
  | otherwise           = partition_args rest (these_srcs ++ srcs) objs
        where phase = startPhase suff
              (slurp,rest) = break (== "-x") args
              these_srcs = zip slurp (repeat (Just phase))
partition_args (arg:args) srcs objs
  | looks_like_an_input arg = partition_args args ((arg,Nothing):srcs) objs
  | otherwise               = partition_args args srcs (arg:objs)

    {-
      We split out the object files (.o, .dll) and add them
      to v_Ld_inputs for use by the linker.

      The following things should be considered compilation manager inputs:

       - haskell source files (strings ending in .hs, .lhs or other
         haskellish extension),

       - module names (not forgetting hierarchical module names),

       - and finally we consider everything not containing a '.' to be
         a comp manager input, as shorthand for a .hs or .lhs filename.

      Everything else is considered to be a linker object, and passed
      straight through to the linker.
    -}
looks_like_an_input :: String -> Bool
looks_like_an_input m =  isSourceFilename m
                      || looksLikeModuleName m
                      || '.' `notElem` m



-- Parsing the mode flag

parseModeFlags :: [Located String]
               -> IO (Mode,
                      [Located String],
                      [Located String])
parseModeFlags args = do
  let ((leftover, errs1, warns), (mModeFlag, errs2, flags')) =
          runCmdLine (processArgs mode_flags args)
                     (Nothing, [], [])
      mode = case mModeFlag of
             Nothing     -> doMakeMode
             Just (m, _) -> m
      errs = errs1 ++ map (mkGeneralLocated "on the commandline") errs2
  when (not (null errs)) $ ghcError $ errorsToGhcException errs
  return (mode, flags' ++ leftover, warns)

type ModeM = CmdLineP (Maybe (Mode, String), [String], [Located String])
  -- mode flags sometimes give rise to new DynFlags (eg. -C, see below)
  -- so we collect the new ones and return them.

mode_flags :: [Flag ModeM]
mode_flags =
  [  ------- help / version ----------------------------------------------
    Flag "?"                     (PassFlag (setMode showGhcUsageMode))
  , Flag "-help"                 (PassFlag (setMode showGhcUsageMode))
  , Flag "V"                     (PassFlag (setMode showVersionMode))
  , Flag "-version"              (PassFlag (setMode showVersionMode))
  , Flag "-numeric-version"      (PassFlag (setMode showNumVersionMode))
  , Flag "-info"                 (PassFlag (setMode showInfoMode))
  , Flag "-supported-languages"  (PassFlag (setMode showSupportedExtensionsMode))
  , Flag "-supported-extensions" (PassFlag (setMode showSupportedExtensionsMode))
  ] ++
  [ Flag k'                      (PassFlag (setMode (printSetting k)))
  | k <- ["Project version",
          "Booter version",
          "Stage",
          "Build platform",
          "Host platform",
          "Target platform",
          "Have interpreter",
          "Object splitting supported",
          "Have native code generator",
          "Support SMP",
          "Unregisterised",
          "Tables next to code",
          "RTS ways",
          "Leading underscore",
          "Debug on",
          "LibDir",
          "Global Package DB",
          "C compiler flags",
          "Gcc Linker flags",
          "Ld Linker flags"],
    let k' = "-print-" ++ map (replaceSpace . toLower) k
        replaceSpace ' ' = '-'
        replaceSpace c   = c
  ] ++
      ------- interfaces ----------------------------------------------------
  [ Flag "-show-iface"  (HasArg (\f -> setMode (showInterfaceMode f)
                                               "--show-iface"))

      ------- primary modes ------------------------------------------------
  , Flag "c"            (PassFlag (\f -> do setMode (stopBeforeMode StopLn) f
                                            addFlag "-no-link" f))
  , Flag "M"            (PassFlag (setMode doMkDependHSMode))
  , Flag "E"            (PassFlag (setMode (stopBeforeMode anyHsc)))
  , Flag "C"            (PassFlag (\f -> do setMode (stopBeforeMode HCc) f
                                            addFlag "-fvia-C" f))
  , Flag "S"            (PassFlag (setMode (stopBeforeMode As)))
  , Flag "-make"        (PassFlag (setMode doMakeMode))
  , Flag "-interactive" (PassFlag (setMode doInteractiveMode))
  , Flag "-abi-hash"    (PassFlag (setMode doAbiHashMode))
  , Flag "e"            (SepArg   (\s -> setMode (doEvalMode s) "-e"))
  ]

setMode :: Mode -> String -> EwM ModeM ()
setMode newMode newFlag = liftEwM $ do
    (mModeFlag, errs, flags') <- getCmdLineState
    let (modeFlag', errs') =
            case mModeFlag of
            Nothing -> ((newMode, newFlag), errs)
            Just (oldMode, oldFlag) ->
                case (oldMode, newMode) of
                    -- -c/--make are allowed together, and mean --make -no-link
                    _ |  isStopLnMode oldMode && isDoMakeMode newMode
                      || isStopLnMode newMode && isDoMakeMode oldMode ->
                      ((doMakeMode, "--make"), [])

                    -- If we have both --help and --interactive then we
                    -- want showGhciUsage
                    _ | isShowGhcUsageMode oldMode &&
                        isDoInteractiveMode newMode ->
                            ((showGhciUsageMode, oldFlag), [])
                      | isShowGhcUsageMode newMode &&
                        isDoInteractiveMode oldMode ->
                            ((showGhciUsageMode, newFlag), [])
                    -- Otherwise, --help/--version/--numeric-version always win
                      | isDominantFlag oldMode -> ((oldMode, oldFlag), [])
                      | isDominantFlag newMode -> ((newMode, newFlag), [])
                    -- We need to accumulate eval flags like "-e foo -e bar"
                    (Right (Right (DoEval esOld)),
                     Right (Right (DoEval [eNew]))) ->
                        ((Right (Right (DoEval (eNew : esOld))), oldFlag),
                         errs)
                    -- Saying e.g. --interactive --interactive is OK
                    _ | oldFlag == newFlag -> ((oldMode, oldFlag), errs)
                    -- Otherwise, complain
                    _ -> let err = flagMismatchErr oldFlag newFlag
                         in ((oldMode, oldFlag), err : errs)
    putCmdLineState (Just modeFlag', errs', flags')
  where isDominantFlag f = isShowGhcUsageMode   f ||
                           isShowGhciUsageMode  f ||
                           isShowVersionMode    f ||
                           isShowNumVersionMode f

flagMismatchErr :: String -> String -> String
flagMismatchErr oldFlag newFlag
    = "cannot use `" ++ oldFlag ++  "' with `" ++ newFlag ++ "'"

addFlag :: String -> String -> EwM ModeM ()
addFlag s flag = liftEwM $ do
  (m, e, flags') <- getCmdLineState
  putCmdLineState (m, e, mkGeneralLocated loc s : flags')
    where loc = "addFlag by " ++ flag ++ " on the commandline"

type Mode = Either PreStartupMode PostStartupMode
type PostStartupMode = Either PreLoadMode PostLoadMode

data PreStartupMode
  = ShowVersion             -- ghc -V/--version
  | ShowNumVersion          -- ghc --numeric-version
  | ShowSupportedExtensions -- ghc --supported-extensions
  | Print String            -- ghc --print-foo

showVersionMode, showNumVersionMode, showSupportedExtensionsMode :: Mode
showVersionMode             = mkPreStartupMode ShowVersion
showNumVersionMode          = mkPreStartupMode ShowNumVersion
showSupportedExtensionsMode = mkPreStartupMode ShowSupportedExtensions

mkPreStartupMode :: PreStartupMode -> Mode
mkPreStartupMode = Left

isShowVersionMode :: Mode -> Bool
isShowVersionMode (Left ShowVersion) = True
isShowVersionMode _ = False

isShowNumVersionMode :: Mode -> Bool
isShowNumVersionMode (Left ShowNumVersion) = True
isShowNumVersionMode _ = False

data PreLoadMode
  = ShowGhcUsage                           -- ghc -?
  | ShowGhciUsage                          -- ghci -?
  | ShowInfo                               -- ghc --info
  | PrintWithDynFlags (DynFlags -> String) -- ghc --print-foo

showGhcUsageMode, showGhciUsageMode, showInfoMode :: Mode
showGhcUsageMode = mkPreLoadMode ShowGhcUsage
showGhciUsageMode = mkPreLoadMode ShowGhciUsage
showInfoMode = mkPreLoadMode ShowInfo

printSetting :: String -> Mode
printSetting k = mkPreLoadMode (PrintWithDynFlags f)
    where f dflags = fromMaybe (panic ("Setting not found: " ++ show k))
#if MIN_VERSION_ghc(7,2,0)
                   $ lookup k (compilerInfo dflags)
#else
                   $ fmap convertPrintable (lookup k compilerInfo)
              where
                convertPrintable (DynFlags.String s) = s
                convertPrintable (DynFlags.FromDynFlags f) = f dflags
#endif

mkPreLoadMode :: PreLoadMode -> Mode
mkPreLoadMode = Right . Left

isShowGhcUsageMode :: Mode -> Bool
isShowGhcUsageMode (Right (Left ShowGhcUsage)) = True
isShowGhcUsageMode _ = False

isShowGhciUsageMode :: Mode -> Bool
isShowGhciUsageMode (Right (Left ShowGhciUsage)) = True
isShowGhciUsageMode _ = False

data PostLoadMode
  = ShowInterface FilePath  -- ghc --show-iface
  | DoMkDependHS            -- ghc -M
  | StopBefore Phase        -- ghc -E | -C | -S
                            -- StopBefore StopLn is the default
  | DoMake                  -- ghc --make
  | DoInteractive           -- ghc --interactive
  | DoEval [String]         -- ghc -e foo -e bar => DoEval ["bar", "foo"]
  | DoAbiHash               -- ghc --abi-hash

doMkDependHSMode, doMakeMode, doInteractiveMode, doAbiHashMode :: Mode
doMkDependHSMode = mkPostLoadMode DoMkDependHS
doMakeMode = mkPostLoadMode DoMake
doInteractiveMode = mkPostLoadMode DoInteractive
doAbiHashMode = mkPostLoadMode DoAbiHash


showInterfaceMode :: FilePath -> Mode
showInterfaceMode fp = mkPostLoadMode (ShowInterface fp)

stopBeforeMode :: Phase -> Mode
stopBeforeMode phase = mkPostLoadMode (StopBefore phase)

doEvalMode :: String -> Mode
doEvalMode str = mkPostLoadMode (DoEval [str])

mkPostLoadMode :: PostLoadMode -> Mode
mkPostLoadMode = Right . Right

isDoInteractiveMode :: Mode -> Bool
isDoInteractiveMode (Right (Right DoInteractive)) = True
isDoInteractiveMode _ = False

isStopLnMode :: Mode -> Bool
isStopLnMode (Right (Right (StopBefore StopLn))) = True
isStopLnMode _ = False

isDoMakeMode :: Mode -> Bool
isDoMakeMode (Right (Right DoMake)) = True
isDoMakeMode _ = False

#ifdef GHCI
isInteractiveMode :: PostLoadMode -> Bool
isInteractiveMode DoInteractive = True
isInteractiveMode _             = False
#endif

-- isInterpretiveMode: byte-code compiler involved
isInterpretiveMode :: PostLoadMode -> Bool
isInterpretiveMode DoInteractive = True
isInterpretiveMode (DoEval _)    = True
isInterpretiveMode _             = False

needsInputsMode :: PostLoadMode -> Bool
needsInputsMode DoMkDependHS    = True
needsInputsMode (StopBefore _)  = True
needsInputsMode DoMake          = True
needsInputsMode _               = False

-- True if we are going to attempt to link in this mode.
-- (we might not actually link, depending on the GhcLink flag)
isLinkMode :: PostLoadMode -> Bool
isLinkMode (StopBefore StopLn) = True
isLinkMode DoMake              = True
isLinkMode DoInteractive       = True
isLinkMode (DoEval _)          = True
isLinkMode _                   = False

isCompManagerMode :: PostLoadMode -> Bool
isCompManagerMode DoMake        = True
isCompManagerMode DoInteractive = True
isCompManagerMode (DoEval _)    = True
isCompManagerMode _             = False
