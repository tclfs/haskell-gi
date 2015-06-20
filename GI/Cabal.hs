{-# LANGUAGE OverloadedStrings #-}
module GI.Cabal
    ( genCabalProject
    , cabalSetupHs
    ) where

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative ((<$>), (<*>))
#endif
import Control.Monad (forM_)
import Control.Monad.IO.Class (liftIO)
import Data.Char (toLower)
import Data.List (intercalate)
import Data.Maybe (fromMaybe)
import Data.Version (Version(..),  showVersion)
import qualified Data.Map as M
import qualified Data.Text as T
import Text.Read

import GI.Code
import GI.Config (Config(..))
import GI.Overrides (pkgConfigMap, cabalPkgVersion)
import GI.PkgConfig (pkgConfigGetVersion)
import GI.ProjectInfo (homepage, license, authors, maintainers)
import GI.Util (padTo)
import GI.SymbolNaming (ucFirst)

import Paths_GObject_Introspection (version)

cabalSetupHs :: String
cabalSetupHs = unlines ["import Distribution.Simple",
                        "",
                        "main = defaultMainWithHooks simpleUserHooks {",
                        "         haddockHook = haddockHook",
                        "       }",
                        "    where",
                        "      haddockHook _ _ _ _ = putStrLn \"Skipping haddock, this package provides no documentation.\""]

lower :: String -> String
lower = map toLower

haskellGIAPIVersion :: Int
haskellGIAPIVersion = (head . versionBranch) version

haskellGIRevision :: String
haskellGIRevision =
    showVersion (Version (tail (versionBranch version)) (versionTags version))

{- |

If the haskell-gi version is of the form x.y and the pkgconfig version
of the package being wrapped is a.b.c, this gives something of the
form x.a.b.y.

This strange seeming-rule is so that the packages that we produce
follow the PVP, assuming that the package being wrapped follows the
usual semantic versioning convention (http://semver.org) that
increases in "a" indicate non-backwards compatible changes, increases
in "b" backwards compatible additions to the API, and increases in "c"
denote API compatible changes (so we do not need to regenerate
bindings for these, at least in principle, so we do not encode them in
the cabal version).

In order to follow the PVP, then everything we need to do in the
haskell-gi side is to increase x everytime the generated API changes
(for a fixed a.b.c version).

In any case, if such "strange" package numbers are undesired, or the
wrapped package does not follow semver, it is possible to add an
explicit cabal-pkg-version override. This needs to be maintained by
hand (including in the list of dependencies of packages depending on
this one), so think carefully before using this override!

-}
giModuleVersion :: Int -> Int -> String
giModuleVersion major minor =
    show haskellGIAPIVersion ++ "." ++ show major ++ "."
             ++ show minor ++ "." ++ haskellGIRevision

-- | Smallest version not backwards compatible with the current
-- version (according to PVP).
nextIncompatibleVersion :: Int -> String
nextIncompatibleVersion major =
    show haskellGIAPIVersion ++ "." ++ show (major+1)

-- | Determine the pkg-config name and installed version (major.minor
-- only) for a given module, or throw an exception if that fails.
tryPkgConfig :: String -> Bool -> M.Map String String ->
                ExcCodeGen (String, Int, Int)
tryPkgConfig name verbose overridenNames =
    liftIO (pkgConfigGetVersion name verbose overridenNames) >>= \case
           Just (n,v) ->
               case readMajorMinor v of
                 Just (major, minor) -> return (n, major, minor)
                 Nothing -> notImplementedError $ "Cannot parse version \""
                            ++ v ++ "\" for module " ++ name
           Nothing -> missingInfoError $ "Could not determine the pkg-config name corresponding to \"" ++ name ++ "\".\n" ++
                      "Try adding an override with the proper package name:\n"
                      ++ "pkg-config-name " ++ name ++ " [matching pkg-config name here]"

-- | Given a string a.b.c..., representing a version number, determine
-- the major and minor versions, i.e. "a" and "b". If successful,
-- return (a,b).
readMajorMinor :: String -> Maybe (Int, Int)
readMajorMinor version =
    case T.splitOn "." (T.pack version) of
      (a:b:_) -> (,) <$> readMaybe (T.unpack a) <*> readMaybe (T.unpack b)
      _ -> Nothing

-- | Try to generate the cabal project. In case of error return the
-- corresponding error string.
genCabalProject :: String -> [String] -> String -> CodeGen (Maybe String)
genCabalProject name deps modulePrefix =
    handleCGExc (return . Just . describeCGError) $ do
      cfg <- config
      let pkMap = pkgConfigMap (overrides cfg)

      line $ "-- Autogenerated, do not edit."
      line $ padTo 20 "name:" ++ "gi-" ++ lower name
      (pcName, major, minor) <- tryPkgConfig name (verbose cfg) pkMap
      let cabalVersion = fromMaybe (giModuleVersion major minor)
                                   (cabalPkgVersion $ overrides cfg)
      line $ padTo 20 "version:" ++ cabalVersion
      line $ padTo 20 "synopsis:" ++ name
               ++ " bindings, autogenerated by haskell-gi"
      line $ padTo 20 "homepage:" ++ homepage
      line $ padTo 20 "license:" ++ license
      line $ padTo 20 "author:" ++ authors
      line $ padTo 20 "maintainer:" ++ maintainers
      line $ padTo 20 "category:" ++ "Bindings"
      line $ padTo 20 "build-type:" ++ "Custom"
      line $ padTo 20 "cabal-version:" ++ ">=1.10"
      blank
      line $ "library"
      indent $ do
        line $ padTo 20 "default-language:" ++ "Haskell2010"
        let base = modulePrefix ++ ucFirst name
        line $ padTo 20 "exposed-modules:" ++
               intercalate ", " [base, base ++ "Attributes", base ++ "Signals"]
        line $ padTo 20 "pkgconfig-depends:" ++ pcName ++ " >= "
                 ++ show major ++ "." ++ show minor
        line $ padTo 20 "build-depends: base >= 4.6 && <4.9,"
        indent $ do
          line $ "GObject-Introspection >= " ++ showVersion version
                 ++ " && < " ++ show (haskellGIAPIVersion + 1) ++ ","
          forM_ deps $ \dep -> do
              (_, depMajor, depMinor) <- tryPkgConfig dep (verbose cfg) pkMap
              line $ "gi-" ++ lower dep ++ " >= "
                       ++ giModuleVersion depMajor depMinor
                       ++ " && < " ++ nextIncompatibleVersion depMajor ++ ","
          -- Our usage of these is very basic, no reason to put any
          -- strong upper bounds.
          line $ "bytestring >= 0.10,"
          line $ "text >= 1.0"

      return Nothing -- successful generation, no error
