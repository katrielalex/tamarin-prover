{- |
Module      :  Types.hs
Description :  Central data type and Yesod typeclass instances.
Copyright   :  (c) 2011 Cedric Staub
License     :  GPL-3

Maintainer  :  Cedric Staub <cstaub@ethz.ch>
Stability   :  experimental
Portability :  non-portable
-}

{-# LANGUAGE
    OverloadedStrings, Rank2Types, QuasiQuotes,
    TypeFamilies, TemplateHaskell, CPP #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Web.Types
  ( WebUI(..)
  , WebUIRoute (..)
  , resourcesWebUI
  , TheoryInfo(..)
  , TheoryPath(..)
  , TheoryOrigin(..)
  , JsonResponse(..)
  , renderPath
  , parsePath
  , joinPath'
  , TheoryIdx
  , TheoryMap
  , ThreadMap
  , GenericHandler
  , Handler
  , GenericWidget
  , Widget
  ) 
where

import Theory

import Yesod.Core
import Yesod.Helpers.Static

import Text.Hamlet
import Text.Printf

import Data.Monoid (mconcat)
import Data.List (intercalate)
import Data.Maybe (listToMaybe)
import Data.Ord (comparing)
import Data.Char (ord, isAlphaNum)
import Data.Time.LocalTime
import Data.Label
import Control.Concurrent

import qualified Data.Map as M
import qualified Data.Text as T

import Control.Monad.IO.Class
import Control.Applicative

------------------------------------------------------------------------------
-- Types
------------------------------------------------------------------------------

-- | Type synonym for a generic handler inside our site.
type GenericHandler m = GGHandler WebUI WebUI m
type Handler a = GHandler WebUI WebUI a

-- | Type synonym for a generic widget inside our site.
type GenericWidget m = GGWidget WebUI (GenericHandler m)
type Widget a = GWidget WebUI WebUI a

-- | Type synonym representing a numeric index for a theory.
type TheoryIdx = Int

-- | Type synonym representing a map of theories.
type TheoryMap = M.Map TheoryIdx TheoryInfo

-- | Type synonym representing a map of threads.
type ThreadMap = M.Map T.Text ThreadId

-- | The so-called site argument for our application, which can hold various
-- information that can use to keep info that needs to be available to the 
-- handler functions.
data WebUI = WebUI
  { getStatic   :: Static
    -- ^ Settings for static file serving.
  , workDir     :: FilePath
    -- ^ The working directory (for storing/loading theories).
  , parseThy    :: MonadIO m => String -> GenericHandler m ClosedTheory
    -- ^ Parse a closed theory according to command-line arguments.
  , closeThy    :: OpenTheory -> IO ClosedTheory
    -- ^ Close an open theory according to command-line arguments.
  , theoryVar  :: MVar TheoryMap
    -- ^ MVar that holds the theory map
  , threadVar  :: MVar ThreadMap
    -- ^ MVar that holds the thread map
  , autosaveProofstate :: Bool
    -- ^ Automatically store theory map
  , debug :: Bool
    -- ^ Output debug messages
  }

-- | Simple data type for generating JSON responses.
data JsonResponse
  = JsonHtml T.Text Content   -- ^ Title and HTML content
  | JsonAlert T.Text          -- ^ Alert/dialog box with message
  | JsonRedirect T.Text       -- ^ Redirect to given URL

-- | Data type representing origin of theory.
-- Command line with file path, upload with filename (not path),
-- or created by interactive mode (e.g. through editing).
data TheoryOrigin = Local FilePath | Upload String | Interactive
     deriving (Show, Eq, Ord)

-- | Data type containg both the theory and it's index, making it easier to 
-- pass the two around (since they are always tied to each other). We also
-- keep some extra bookkeeping information.
data TheoryInfo = TheoryInfo
  { tiIndex     :: TheoryIdx       -- ^ Index of theory.
  , tiTheory    :: ClosedTheory    -- ^ The closed theory.
  , tiTime      :: ZonedTime       -- ^ Time theory was loaded.
  , tiParent    :: Maybe TheoryIdx -- ^ Prev theory in history
  , tiPrimary   :: Bool            -- ^ This is the orginally loaded theory.
  , tiOrigin    :: TheoryOrigin    -- ^ Origin of theory.
  }

-- | We use the ordering in order to display loaded theories to the user.
-- We first compare by name, then by time loaded, and then by source: Theories
-- that were loaded from the command-line are displayed earlier then
-- interactively loaded ones.
compareTI :: TheoryInfo -> TheoryInfo -> Ordering
compareTI (TheoryInfo _ i1 t1 p1 a1 o1) (TheoryInfo _ i2 t2 p2 a2 o2) =
  mconcat
    [ comparing (get thyName) i1 i2
    , comparing zonedTimeToUTC t1 t2
    , compare a1 a2
    , compare p1 p2
    , compare o1 o2
    ]

instance Eq TheoryInfo where
  (==) t1 t2 = compareTI t1 t2 == EQ

instance Ord TheoryInfo where
  compare = compareTI

-- Adapted from the output of 'derive'.
instance Read CaseDistKind where
        readsPrec p0 r
          = readParen (p0 > 10)
              (\ r0 ->
                 [(UntypedCaseDist, r1) | ("untyped", r1) <- lex r0])
              r
              ++
              readParen (p0 > 10)
                (\ r0 -> [(TypedCaseDist, r1) | ("typed", r1) <- lex r0])
                r

-- | Simple data type for specifying a path to a specific
-- item within a theory.
data TheoryPath
  = TheoryMain                          -- ^ The main view (info about theory)
  | TheoryLemma String                  -- ^ Theory lemma with given name
  | TheoryIntrVar Int                   -- ^ Intruder variant (n'th from start)
  | TheoryCaseDist CaseDistKind Int Int -- ^ Required cases (i'th source, j'th case) 
  | TheoryProof String ProofPath        -- ^ Proof path within proof for given lemma
  | TheoryMethod String ProofPath Int   -- ^ Apply the proof method to proof path
  | TheoryRules                         -- ^ Theory rules
  deriving (Eq, Show, Read)

-- | Render a theory path to a list of strings.
renderPath :: TheoryPath -> [String]
renderPath TheoryMain = ["main"]
renderPath TheoryRules = ["rules"]
renderPath (TheoryLemma name) = ["lemma", name]
renderPath (TheoryIntrVar i) = ["variant", show i]
renderPath (TheoryCaseDist k i j) = ["cases", show k, show i, show j]
renderPath (TheoryProof lemma path) = "proof" : lemma : path
renderPath (TheoryMethod lemma path idx) = "method" : lemma : show idx : path

-- | Parse a list of strings into a theory path.
parsePath :: [String] -> Maybe TheoryPath
parsePath []     = Nothing
parsePath (x:xs) = case x of
  "main"    -> Just TheoryMain
  "rules"   -> Just TheoryRules
  "lemma"   -> parseLemma xs
  "cases"   -> parseCases xs
  "variant" -> parseVariant xs
  "proof"   -> parseProof xs
  "method"  -> parseMethod xs
  _         -> Nothing 
  where
    safeRead = listToMaybe . map fst . reads

    parseLemma ys = TheoryLemma <$> listToMaybe ys

    parseProof (y:ys) = Just (TheoryProof y ys)
    parseProof _      = Nothing 

    parseMethod (y:z:zs) = safeRead z >>= Just . TheoryMethod y zs
    parseMethod _        = Nothing

    parseVariant (y:_) = safeRead y >>= Just . TheoryIntrVar
    parseVariant _     = Nothing

    parseCases (kind:y:z:_) = do
      k <- case kind of "typed"   -> return TypedCaseDist 
                        "untyped" -> return UntypedCaseDist
                        _         -> Nothing
      m <- safeRead y
      n <- safeRead z
      return (TheoryCaseDist k m n)
    parseCases _       = Nothing


-- | Join a path (list of strings) into a single string.
-- This functions also performs escaping of special characters.
joinPath' :: [String] -> String
joinPath' = intercalate "/" . map escape
  where
    escape [] = []
    escape (x:xs)
      | isAlphaNum x = x : escape xs
      | otherwise = printf "%%%02x" (ord x) ++ escape xs

------------------------------------------------------------------------------
-- Routing
------------------------------------------------------------------------------

-- Quasi-quotation syntax changed from GHC 6 to 7,
-- so we need this switch in order to support both.
#if __GLASGOW_HASKELL__ >= 700
#define HAMLET hamlet
#define PARSE_ROUTES parseRoutes
#else
#define HAMLET $hamlet
#define PARSE_ROUTES $parseRoutes
#endif

-- This is a hack we need to work around a bug (?) in the
-- C pre-processor. In order to define multi-pieces we need
-- the asterisk symbol, but the C pre-processor always chokes
-- on them thinking that they are somehow comments. This can
-- be removed once the CPP language ext is disabled, but it's
-- currently needed for GHC < 7 support.
#define MP(x) *x

-- | Static routing for our application.
-- Note that handlers ending in R are general handlers,
-- whereas handlers ending in MR are for the main view
-- and the ones ending in DR are for the debug view.
mkYesodData "WebUI" [PARSE_ROUTES|
/ RootR GET POST
/thy/#Int/overview OverviewR GET
/thy/#Int/source TheorySourceR GET
/thy/#Int/variants TheoryVariantsR GET
/thy/#Int/main/MP(TheoryPath) TheoryPathMR GET
/thy/#Int/debug/MP(TheoryPath) TheoryPathDR GET
/thy/#Int/graph/MP(TheoryPath) TheoryGraphR GET
/thy/#Int/autoprove/MP(TheoryPath) AutoProverR GET
/thy/#Int/next/#String/MP(TheoryPath) NextTheoryPathR GET
/thy/#Int/prev/#String/MP(TheoryPath) PrevTheoryPathR GET
/thy/#Int/save SaveTheoryR GET
/thy/#Int/download/#String DownloadTheoryR GET
/thy/#Int/edit/source EditTheoryR GET POST
/thy/#Int/edit/path/MP(TheoryPath) EditPathR GET POST
/thy/#Int/del/path/MP(TheoryPath) DeleteStepR GET
/thy/#Int/unload UnloadTheoryR GET
/kill KillThreadR GET
/threads ThreadsR GET
/robots.txt RobotsR GET
/favicon.ico FaviconR GET
/static StaticR Static getStatic
|]

-- | MultiPiece instance for TheoryPath.
instance MultiPiece TheoryPath where
  toMultiPiece = map T.pack . renderPath
  fromMultiPiece = parsePath . map T.unpack

-- Instance of the Yesod typeclass.
instance Yesod WebUI where
  -- | The approot. We can leave this empty because the
  -- application is always served from the root of the server.
  approot _ = T.empty

  -- | The default layout for rendering.
  defaultLayout = defaultLayout'

  -- | The path cleaning function. We make sure empty strings
  -- are not scrubbed from the end of the list. The default
  -- cleanPath function forces canonical URLs.
  cleanPath _ = Right


------------------------------------------------------------------------------
-- Default layout
------------------------------------------------------------------------------

-- | Our application's default layout template.
-- Note: We define the default layout here even tough it doesn't really
-- belong in the "types" module in order to avoid mutually recursive modules.
defaultLayout' :: (Yesod master, Route master ~ WebUIRoute) 
               => GWidget sub master ()      -- ^ Widget to embed in layout
               -> GHandler sub master RepHtml
defaultLayout' w = do
  page <- widgetToPageContent w
  message <- getMessage
  hamletToRepHtml [HAMLET|
    !!!
    <html>
      <head>
        <title>#{pageTitle page}
        <link rel=stylesheet href=/static/css/tamarin-prover-ui.css>
        <link rel=stylesheet href=/static/css/jquery-contextmenu.css>
        <link rel=stylesheet href=/static/css/smoothness/jquery-ui.css>
        <script src=/static/js/jquery.js></script>
        <script src=/static/js/jquery-ui.js></script>
        <script src=/static/js/jquery-layout.js></script>
        <script src=/static/js/jquery-cookie.js></script>
        <script src=/static/js/jquery-superfish.js></script>
        <script src=/static/js/jquery-contextmenu.js></script>
        <script src=/static/js/tamarin-prover-ui.js></script>
        ^{pageHead page}
      <body>
        $maybe msg <- message
          <p.message>#{msg}
        <p.loading>
          Loading, please wait...
          \  <a id=cancel href='#'>Cancel</a>
        ^{pageBody page}
        <div#dialog>
        <ul#contextMenu>
          <li.autoprove>
            <a href="#autoprove">Autoprove</a>
          <li.delstep>
            <a href="#del/path">Remove step</a>
  |]