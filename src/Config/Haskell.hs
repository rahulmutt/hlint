{-# LANGUAGE PatternGuards, ViewPatterns #-}

module Config.Haskell(
    readPragma,
    addInfix,
    findSettings,
    readSettings, readSettings2
    ) where

import Data.Monoid
import HSE.All
import Control.Monad.Extra
import Data.Char
import Data.Either
import Data.List.Extra
import System.FilePath
import Config.Type
import Util
import Prelude


getSeverity :: String -> Maybe Severity
getSeverity "ignore" = Just Ignore
getSeverity "warn" = Just Warning
getSeverity "warning" = Just Warning
getSeverity "suggest" = Just Suggestion
getSeverity "suggestion" = Just Suggestion
getSeverity "error" = Just Error
getSeverity "hint" = Just Suggestion
getSeverity _ = Nothing


addInfix = parseFlagsAddFixities $ infix_ (-1) ["==>"]


---------------------------------------------------------------------
-- READ A SETTINGS FILE

-- Given a list of hint files to start from
-- Return the list of settings commands
readSettings2 :: [FilePath] -> [String] -> IO [Setting]
readSettings2 files hints = do
    mods <- mapM readHints $ map Right files ++ map Left hints
    return $ concatMap moduleSettings_ mods

moduleSettings_ :: Module_ -> [Setting]
moduleSettings_ m = concatMap (readSetting $ scopeCreate m) $ concatMap getEquations $
                       [AnnPragma l x | AnnModulePragma l x <- modulePragmas m] ++ moduleDecls m

-- | Given a module containing HLint settings information return the 'Classify' rules and the 'HintRule' expressions.
--   Any fixity declarations will be discarded, but any other unrecognised elements will result in an exception.
readSettings :: Module_ -> ([Classify], [HintRule])
readSettings m = ([x | SettingClassify x <- xs], [x | SettingMatchExp x <- xs])
    where xs = moduleSettings_ m


readHints :: Either String FilePath -> IO Module_
readHints x = case x of
    Left src -> findSettingsFiles "CommandLine" (Just src)
    Right file -> findSettingsFiles file Nothing


-- | Given the data directory (where the @hlint@ data files reside, see 'getHLintDataDir'),
--   and a filename to read, and optionally that file's contents, produce a pair containing:
--
-- 1. Builtin hints to use, e.g. @"List"@, which should be resolved using 'builtinHints'.
--
-- 1. A list of modules containing hints, suitable for processing with 'readSettings'.
--
--   Any parse failures will result in an exception.
findSettingsFiles :: FilePath -> Maybe String -> IO Module_
findSettingsFiles file contents = do
    let flags = addInfix defaultParseFlags
    res <- parseModuleEx flags file contents
    case res of
        Left (ParseError sl msg err) -> exitMessage $ "Parse failure at " ++ showSrcLoc sl ++ ": " ++ msg ++ "\n" ++ err
        Right (m, _) -> return m


readSetting :: Scope -> Decl_ -> [Setting]
readSetting s (FunBind _ [Match _ (Ident _ (getSeverity -> Just severity)) pats (UnGuardedRhs _ bod) bind])
    | InfixApp _ lhs op rhs <- bod, opExp op ~= "==>" =
        let (a,b) = readSide $ childrenBi bind in
        [SettingMatchExp $ HintRule severity (head $ snoc names defaultHintName) s (fromParen lhs) (fromParen rhs) a b]
    | otherwise = [SettingClassify $ Classify severity n a b | n <- names2, (a,b) <- readFuncs bod]
    where
        names = filter (not . null) $ getNames pats bod
        names2 = ["" | null names] ++ names

readSetting s x | "test" `isPrefixOf` map toLower (fromNamed x) = []
readSetting s (AnnPragma _ x) | Just y <- readPragma x = [SettingClassify y]
readSetting s (PatBind an (PVar _ name) bod bind) = readSetting s $ FunBind an [Match an name [] bod bind]
readSetting s (FunBind an xs) | length xs /= 1 = concatMap (readSetting s . FunBind an . return) xs
readSetting s (SpliceDecl an (App _ (Var _ x) (Lit _ y))) = readSetting s $ FunBind an [Match an (toNamed $ fromNamed x) [PLit an (Signless an) y] (UnGuardedRhs an $ Lit an $ String an "" "") Nothing]
readSetting s x@InfixDecl{} = map Infix $ getFixity x
readSetting s x = errorOn x "bad hint"


-- | Read an {-# ANN #-} pragma and determine if it is intended for HLint.
--   Return Nothing if it is not an HLint pragma, otherwise what it means.
readPragma :: Annotation S -> Maybe Classify
readPragma o = case o of
    Ann _ name x -> f (fromNamed name) x
    TypeAnn _ name x -> f (fromNamed name) x
    ModuleAnn _ x -> f "" x
    where
        f name (Lit _ (String _ s _)) | "hlint:" `isPrefixOf` map toLower s =
                case getSeverity a of
                    Nothing -> errorOn o "bad classify pragma"
                    Just severity -> Just $ Classify severity (trimStart b) "" name
            where (a,b) = break isSpace $ trimStart $ drop 6 s
        f name (Paren _ x) = f name x
        f name (ExpTypeSig _ x _) = f name x
        f _ _ = Nothing


readSide :: [Decl_] -> (Maybe Exp_, [Note])
readSide = foldl f (Nothing,[])
    where f (Nothing,notes) (PatBind _ PWildCard{} (UnGuardedRhs _ side) Nothing) = (Just side, notes)
          f (Nothing,notes) (PatBind _ (fromNamed -> "side") (UnGuardedRhs _ side) Nothing) = (Just side, notes)
          f (side,[]) (PatBind _ (fromNamed -> "note") (UnGuardedRhs _ note) Nothing) = (side,g note)
          f _ x = errorOn x "bad side condition"

          g (Lit _ (String _ x _)) = [Note x]
          g (List _ xs) = concatMap g xs
          g x = case fromApps x of
              [con -> Just "IncreasesLaziness"] -> [IncreasesLaziness]
              [con -> Just "DecreasesLaziness"] -> [DecreasesLaziness]
              [con -> Just "RemovesError",fromString -> Just a] -> [RemovesError a]
              [con -> Just "ValidInstance",fromString -> Just a,var -> Just b] -> [ValidInstance a b]
              _ -> errorOn x "bad note"

          con :: Exp_ -> Maybe String
          con c@Con{} = Just $ prettyPrint c; con _ = Nothing
          var c@Var{} = Just $ prettyPrint c; var _ = Nothing


-- Note: Foo may be ("","Foo") or ("Foo",""), return both
readFuncs :: Exp_ -> [(String, String)]
readFuncs (App _ x y) = readFuncs x ++ readFuncs y
readFuncs (Lit _ (String _ "" _)) = [("","")]
readFuncs (Var _ (UnQual _ name)) = [("",fromNamed name)]
readFuncs (Var _ (Qual _ (ModuleName _ mod) name)) = [(mod, fromNamed name)]
readFuncs (Con _ (UnQual _ name)) = [(fromNamed name,""),("",fromNamed name)]
readFuncs (Con _ (Qual _ (ModuleName _ mod) name)) = [(mod ++ "." ++ fromNamed name,""),(mod,fromNamed name)]
readFuncs x = errorOn x "bad classification rule"


getNames :: [Pat_] -> Exp_ -> [String]
getNames ps _ | ps /= [], Just ps <- mapM fromPString ps = ps
getNames [] (InfixApp _ lhs op rhs) | opExp op ~= "==>" = map ("Use "++) names
    where
        lnames = map f $ childrenS lhs
        rnames = map f $ childrenS rhs
        names = filter (not . isUnifyVar) $ (rnames \\ lnames) ++ rnames
        f (Ident _ x) = x
        f (Symbol _ x) = x
getNames _ _ = []


errorOn :: (Annotated ast, Pretty (ast S)) => ast S -> String -> b
errorOn val msg = exitMessage $
    showSrcLoc (getPointLoc $ ann val) ++
    ": Error while reading hint file, " ++ msg ++ "\n" ++
    prettyPrint val


---------------------------------------------------------------------
-- FIND SETTINGS IN A SOURCE FILE

-- | Given a source file, guess some hints that might apply.
--   Returns the text of the hints (if you want to save it down) along with the settings to be used.
findSettings :: ParseFlags -> FilePath -> IO (String, [Setting])
findSettings flags file = do
    x <- parseModuleEx flags file Nothing
    case x of
        Left (ParseError sl msg _) ->
            return ("-- Parse error " ++ showSrcLoc sl ++ ": " ++ msg, [])
        Right (m, _) -> do
            let xs = concatMap (findSetting $ UnQual an) (moduleDecls m)
                s = unlines $ ["-- hints found in " ++ file] ++ map prettyPrint xs ++ ["-- no hints found" | null xs]
                r = concatMap (readSetting mempty) xs
            return (s,r)


findSetting :: (Name S -> QName S) -> Decl_ -> [Decl_]
findSetting qual (InstDecl _ _ _ (Just xs)) = concatMap (findSetting qual) [x | InsDecl _ x <- xs]
findSetting qual (PatBind _ (PVar _ name) (UnGuardedRhs _ bod) Nothing) = findExp (qual name) [] bod
findSetting qual (FunBind _ [InfixMatch _ p1 name ps rhs bind]) = findSetting qual $ FunBind an [Match an name (p1:ps) rhs bind]
findSetting qual (FunBind _ [Match _ name ps (UnGuardedRhs _ bod) Nothing]) = findExp (qual name) [] $ Lambda an ps bod
findSetting _ x@InfixDecl{} = [x]
findSetting _ _ = []


-- given a result function name, a list of variables, a body expression, give some hints
findExp :: QName S -> [String] -> Exp_ -> [Decl_]
findExp name vs (Lambda _ ps bod) | length ps2 == length ps = findExp name (vs++ps2) bod
                                  | otherwise = []
    where ps2 = [x | PVar_ x <- map view ps]
findExp name vs Var{} = []
findExp name vs (InfixApp _ x dot y) | isDot dot = findExp name (vs++["_hlint"]) $ App an x $ Paren an $ App an y (toNamed "_hlint")

findExp name vs bod = [PatBind an (toNamed "warn") (UnGuardedRhs an $ InfixApp an lhs (toNamed "==>") rhs) Nothing]
    where
        lhs = g $ transform f bod
        rhs = apps $ Var an name : map snd rep

        rep = zip vs $ map (toNamed . return) ['a'..]
        f xx | Var_ x <- view xx, Just y <- lookup x rep = y
        f (InfixApp _ x dol y) | isDol dol = App an x (paren y)
        f x = x

        g o@(InfixApp _ _ _ x) | isAnyApp x || isAtom x = o
        g o@App{} = o
        g o = paren o
