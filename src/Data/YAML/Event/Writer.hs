{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE Safe              #-}

{-# OPTIONS_GHC -fno-warn-unused-matches #-} -- TODO

-- |
-- Copyright: © Herbert Valerio Riedel 2015-2018
-- SPDX-License-Identifier: GPL-2.0-or-later
--
-- Event-stream oriented YAML writer API
--
module Data.YAML.Event.Writer
    ( writeEvents
    , writeEventsText
    ) where

import           Data.YAML.Event.Internal

import qualified Data.ByteString.Lazy     as BS.L
import qualified Data.Char                as C
import qualified Data.Map                 as Map
import qualified Data.Text                as T
import           Text.Printf              (printf)

import qualified Data.Text.Lazy           as T.L
import qualified Data.Text.Lazy.Builder   as T.B
import qualified Data.Text.Lazy.Encoding  as T.L

import           Util


{- WARNING: the code that follows will make you cry; a safety pig is provided below for your benefit.

                         _
 _._ _..._ .-',     _.._(`))
'-. `     '  /-._.-'    ',/
   )         \            '.
  / _    _    |             \
 |  a    a    /              |
 \   .-.                     ;
  '-('' ).-'       ,'       ;
     '-;           |      .'
        \           \    /
        | 7  .__  _.-\   \
        | |  |  ``/  /`  /
       /,_|  |   /,_/   /
          /,_/      '`-'

-}

-- | Serialise 'Event's using specified UTF encoding to a lazy 'BS.L.ByteString'
--
-- __NOTE__: This function is only well-defined for valid 'Event' streams
--
-- @since 0.2.0.0
writeEvents :: Encoding -> [Event] -> BS.L.ByteString
writeEvents UTF8    = T.L.encodeUtf8    . writeEventsText
writeEvents UTF16LE = T.L.encodeUtf16LE . T.L.cons '\xfeff' . writeEventsText
writeEvents UTF16BE = T.L.encodeUtf16BE . T.L.cons '\xfeff' . writeEventsText
writeEvents UTF32LE = T.L.encodeUtf32LE . T.L.cons '\xfeff' . writeEventsText
writeEvents UTF32BE = T.L.encodeUtf32BE . T.L.cons '\xfeff' . writeEventsText

-- | Serialise 'Event's to lazy 'T.L.Text'
--
-- __NOTE__: This function is only well-defined for valid 'Event' streams
--
-- @since 0.2.0.0
writeEventsText :: [Event] -> T.L.Text
writeEventsText [] = mempty
writeEventsText (StreamStart:xs) = T.B.toLazyText $ goStream xs (error "writeEvents: internal error")
  where
    -- goStream :: [Event] -> [Event] -> T.B.Builder
    goStream [StreamEnd] _ = mempty
    goStream (StreamEnd : _ : rest) _cont = error "writeEvents: events after StreamEnd"
    goStream (DocumentStart marker : rest) cont
      = case marker of
          NoDirEndMarker         -> putNode False rest (\zs -> goDoc zs cont)
          DirEndMarkerNoVersion  -> "---" <> putNode True rest (\zs -> goDoc zs cont)
          DirEndMarkerVersion mi -> "%YAML 1." <> (T.B.fromString (show mi)) <> "\n---" <> putNode True rest (\zs -> goDoc zs cont)
    goStream (x:_) _cont = error ("writeEvents: unexpected " ++ show x ++ " (expected DocumentStart or StreamEnd)")
    goStream [] _cont = error ("writeEvents: unexpected end of stream (expected DocumentStart or StreamEnd)")

    goDoc (DocumentEnd marker : rest) cont
      = (if marker then "...\n" else mempty) <> goStream rest cont
    goDoc ys _ = error (show ys)

    -- unexpected s l = error ("writeEvents: unexpected " ++ show l ++ " " ++ show s)

writeEventsText (x:_) = error ("writeEvents: unexpected " ++ show x ++ " (expected StreamStart)")

-- | Production context -- copied from Data.YAML.Token
data Context = BlockOut     -- ^ Outside block sequence.
             | BlockIn      -- ^ Inside block sequence.
             | BlockKey     -- ^ Implicit block key.
             -- | FlowOut      -- ^ Outside flow collection.
             -- | FlowIn       -- ^ Inside flow collection.
             -- | FlowKey      -- ^ Implicit flow key.
             deriving (Eq,Show)

putNode :: Bool -> [Event] -> ([Event] -> T.B.Builder) -> T.B.Builder
putNode = \docMarker -> go (-1 :: Int) (not docMarker) BlockIn
  where

    {-  s-l+block-node(n,c)

        [196]   s-l+block-node(n,c)        ::=     s-l+block-in-block(n,c) | s-l+flow-in-block(n)

        [197]   s-l+flow-in-block(n)       ::=     s-separate(n+1,flow-out) ns-flow-node(n+1,flow-out) s-l-comments

        [198]   s-l+block-in-block(n,c)    ::=     s-l+block-scalar(n,c) | s-l+block-collection(n,c)

        [199]   s-l+block-scalar(n,c)      ::=     s-separate(n+1,c) ( c-ns-properties(n+1,c) s-separate(n+1,c) )?  ( c-l+literal(n) | c-l+folded(n) )

        [200]   s-l+block-collection(n,c)  ::=     ( s-separate(n+1,c) c-ns-properties(n+1,c) )? s-l-comments
                                                   ( l+block-sequence(seq-spaces(n,c)) | l+block-mapping(n) )

        [201]   seq-spaces(n,c)            ::=     c = block-out ⇒ n-1
                                                   c = block-in  ⇒ n

    -}

    go :: Int -> Bool -> Context -> [Event] -> ([Event] -> T.B.Builder) -> T.B.Builder
    go _  _ _  [] _cont = error ("putNode: expected node-start event instead of end-of-stream")
    go !n !sol c (t : rest) cont = case t of
        Scalar        anc tag sty t' -> goStr (n+1) sol c anc tag sty t' (cont rest)
        SequenceStart anc tag sty    -> goSeq (n+1) sol c anc tag sty rest cont
        MappingStart  anc tag sty    -> goMap (n+1) sol c anc tag sty rest cont
        Alias a                      -> pfx <> goAlias c a (cont rest)

        _ -> error ("putNode: expected node-start event instead of " ++ show t)
      where
        pfx | sol           = mempty
            | BlockKey <- c = mempty
            | otherwise     = T.B.singleton ' '


    goMap n sol c anc tag sty (MappingEnd : rest) cont = pfx $ "{}\n" <> cont rest
      where
        pfx cont' = (if sol then mempty else ws) <> anchorTag'' (Right ws) anc tag cont'

    goMap n sol c anc tag sty xs cont = case c of
        BlockIn | not (not sol && n == 0) -- avoid "--- " case
           ->  (if sol then mempty else ws) <> anchorTag'' (Right (eol <> mkInd n)) anc tag
               (putKey xs (\ys -> go n False BlockOut ys g))
        _  ->  anchorTag'' (Left ws) anc tag $ T.B.singleton '\n' <> g xs
      where
        g (MappingEnd : rest) = cont rest
        g ys                  = pfx <> putKey ys (\zs -> go n False BlockOut zs g)

        pfx = mkInd n

        putKey zs cont2
          | isSmallKey zs =    go n (n == 0) BlockKey zs (\ys -> ":" <> cont2 ys)
          | otherwise     = "?" <> go n False BlockIn zs (\ys -> mkInd n <> ":" <> cont2 ys)



    goSeq n sol c anc tag sty (SequenceEnd : rest) cont = pfx $ "[]\n" <> cont rest
      where
        pfx cont' = (if sol then mempty else ws) <> anchorTag'' (Right ws) anc tag cont'

    goSeq n sol c anc tag sty xs cont = case c of
        BlockOut -> anchorTag'' (Left ws) anc tag (eol <> mkInd n' <> "-" <> go n' False c' xs g)

        BlockIn
          | not sol && n == 0 {- "---" case -} -> goSeq n sol BlockOut anc tag sty xs cont
          | otherwise -> (if sol then mempty else ws) <> anchorTag'' (Right (eol <> mkInd n')) anc tag ("-" <> go n' False c' xs g)

        BlockKey -> error ("sequence in block-key context not supported")

      where
        c' = BlockIn
        n' | BlockOut <- c = max 0 (n - 1)
           | otherwise     = n

        g (SequenceEnd : rest) = cont rest
        g ys                   = mkInd n' <> "-" <> go n' False c' ys g


    goAlias c a cont = T.B.singleton '*' <> T.B.fromText a <> sep <> cont
      where
        sep = case c of
          BlockIn  -> eol
          BlockOut -> eol
          BlockKey -> T.B.singleton ' '

    goStr :: Int -> Bool -> Context -> Maybe Anchor -> Tag -> ScalarStyle -> Text -> T.B.Builder -> T.B.Builder
--    goStr !n !sol c anc tag sty t cont | traceShow (n,sol,c,anc,tag,sty,t) False = undefined
    goStr !n !sol c anc tag sty t cont = case sty of
      -- flow-style

      Plain -- empty scalars
        | t == "", Nothing <- anc, Tag Nothing <- tag -> contEol -- not even node properties
        | sol, t == "" -> anchorTag0            anc tag (if c == BlockKey then ws <> cont else contEol)
        | t == "", BlockKey <- c   -> anchorTag0 anc tag (if c == BlockKey then ws <> cont else contEol)
        | t == ""      -> anchorTag'' (Left ws) anc tag contEol

      Plain           -> pfx $
                          let h []     = contEol
                              h (x:xs) = T.B.fromText x <> f' xs
                                where
                                  f' []     = contEol
                                  f' (y:ys) = eol <> mkInd (n+1) <> T.B.fromText y <> f' ys
                          in h (insFoldNls (T.lines t)) -- FIXME: unquoted plain-strings can't handle leading/trailing whitespace properly

      SingleQuoted    -> pfx $ T.B.singleton '\'' <> f (insFoldNls $ T.lines (T.replace "'" "''" t) ++ [ mempty | T.isSuffixOf "\n" t]) (T.B.singleton '\'' <> contEol) -- FIXME: leading white-space (i.e. SPC) before/after LF

      DoubleQuoted    -> pfx $ T.B.singleton '"'  <> T.B.fromText (escapeDQ t) <> T.B.singleton '"'  <> contEol

      -- block-style
      Folded  --- FIXME/TODO: T.lines eats trailing whitespace; check this works out properly!
        | T.null t                -> pfx $ ">" <> eol <> cont
        | hasLeadSpace t          -> pfx $ (if T.last t == '\n' then ">2" else ">2-") <> g (insFoldNls' $ T.lines t) cont
        | T.last t == '\n'        -> pfx $ T.B.singleton '>'  <> g (insFoldNls' $ T.lines t) cont
        | otherwise               -> pfx $ ">-"               <> g (insFoldNls' $ T.lines t) cont

      Literal -- TODO: indent-indicator for leading space payloads
        | T.null t                -> pfx $ "|" <> eol <> cont
        | "\n" == t               -> pfx $ "|+"              <> g (T.lines t) cont
        | hasLeadSpace t          -> pfx $ "|2"              <> g (T.lines t) cont
        | "\n\n" `T.isSuffixOf` t -> pfx $ "|+"              <> g (T.lines t) cont
        | "\n"   `T.isSuffixOf` t -> pfx $ T.B.singleton '|' <> g (T.lines t) cont
        | otherwise               -> pfx $ "|-"              <> g (T.lines t) cont

      where
        hasLeadSpace t' = T.isPrefixOf " " . T.dropWhile (== '\n') $ t'

        pfx cont' = (if sol || c == BlockKey then mempty else ws) <> anchorTag'' (Right ws) anc tag cont'

        doEol = case c of
          BlockKey -> False
          _        -> True

        contEol
          | doEol     = eol <> cont
          | otherwise = cont

        g []     cont' = eol <> cont'
        g (x:xs) cont'
          | T.null x   = eol <> g xs cont'
          | otherwise  = eol <> mkInd n <> T.B.fromText x <> g xs cont'

        g' []     cont' = cont'
        g' (x:xs) cont' = eol <> mkInd (n+1) <> T.B.fromText x <> g' xs cont'

        f []     cont' = cont'
        f (x:xs) cont' = T.B.fromText x <> g' xs cont'




    isSmallKey (Alias _ : _)              = True
    isSmallKey (Scalar _ _ Folded _ : _)  = False
    isSmallKey (Scalar _ _ Literal _ : _) = False
    isSmallKey (Scalar _ _ _ _ : _)       = True
    isSmallKey (SequenceStart _ _ _ : _)  = False
    isSmallKey (MappingStart _ _ _ : _)   = False
    isSmallKey _                          = False




    putTag t cont
      | Just t' <- T.stripPrefix "tag:yaml.org,2002:" t = "!!" <> T.B.fromText t' <> cont
      | "!" `T.isPrefixOf` t = T.B.fromText t <> cont
      | otherwise            = "!<" <> T.B.fromText t <> T.B.singleton '>' <> cont

    anchorTag'' :: Either T.B.Builder T.B.Builder -> Maybe Anchor -> Tag -> T.B.Builder -> T.B.Builder
    anchorTag'' _ Nothing (Tag Nothing) cont = cont
    anchorTag'' (Right pad) Nothing (Tag (Just t)) cont  = putTag t (pad <> cont)
    anchorTag'' (Right pad) (Just a) (Tag Nothing) cont  = T.B.singleton '&' <> T.B.fromText a <> pad <> cont
    anchorTag'' (Right pad) (Just a) (Tag (Just t)) cont = T.B.singleton '&' <> T.B.fromText a <> T.B.singleton ' ' <> putTag t (pad <> cont)
    anchorTag'' (Left pad)  Nothing (Tag (Just t)) cont  = pad <> putTag t cont
    anchorTag'' (Left pad)  (Just a) (Tag Nothing) cont  = pad <> T.B.singleton '&' <> T.B.fromText a <> cont
    anchorTag'' (Left pad)  (Just a) (Tag (Just t)) cont = pad <> T.B.singleton '&' <> T.B.fromText a <> T.B.singleton ' ' <> putTag t cont

    anchorTag0 = anchorTag'' (Left mempty)
    -- anchorTag  = anchorTag'' (Right (T.B.singleton ' '))
    -- anchorTag' = anchorTag'' (Left (T.B.singleton ' '))

    -- indentation helper
    mkInd (-1) = mempty
    mkInd 0    = mempty
    mkInd 1 = "  "
    mkInd 2 = "    "
    mkInd 3 = "      "
    mkInd 4 = "        "
    mkInd l
      | l < 0     = error (show l)
      | otherwise = T.B.fromText (T.replicate l "  ")


    eol = T.B.singleton '\n'
    ws  = T.B.singleton ' '


escapeDQ :: Text -> Text
escapeDQ t -- TODO: review "printable" definition in YAML 1.2 spec
  | T.all (\c -> C.isPrint c && c /= '\n' && c /= '"') t = t
  | otherwise = T.concatMap escapeChar t

escapeChar :: Char -> Text
escapeChar c
  | c == '\\'   = "\\\\"
  | c == '"'    = "\\\""
  | C.isPrint c = T.singleton c
  | Just e <- Map.lookup c emap = e
  | x <= 0xff   = T.pack (printf "\\x%02x" x)
  | x <= 0xffff = T.pack (printf "\\u%04x" x)
  | otherwise   = T.pack (printf "\\U%08x" x)
  where
    x = ord c

    emap = Map.fromList [ (v,T.pack ['\\',k]) | (k,v) <- escapes ]


escapes :: [(Char,Char)]
escapes =
  [ ('0',   '\0')
  , ('a',   '\x7')
  , ('b',   '\x8')
  , ('\x9', '\x9')
  , ('t',   '\x9')
  , ('n',   '\xa')
  , ('v',   '\xb')
  , ('f',   '\xc')
  , ('r',   '\xd')
  , ('e',   '\x1b')
  , (' ',   ' ')
  , ('"',   '"')
  , ('/',   '/')
  , ('\\',  '\\')
  , ('N',   '\x85')
  , ('_',   '\xa0')
  , ('L',   '\x2028')
  , ('P',   '\x2029')
  ]


-- flow style line folding
-- FIXME: check single-quoted strings with leading '\n' or trailing '\n's
insFoldNls :: [Text] -> [Text]
insFoldNls [] = []
insFoldNls (z:zs)
  | all T.null (z:zs) = "" : z : zs -- HACK
  | otherwise         = z : go zs
  where
    go [] = []
    go (l:ls)
      | T.null l = l : go'  ls
      | otherwise = "" : l : go  ls

    go' [] = [""]
    go' (l:ls)
      | T.null l = l : go' ls
      | otherwise = "" : l : go  ls

{- block style line folding

The combined effect of the block line folding rules is that each
“paragraph” is interpreted as a line, empty lines are interpreted as a
line feed, and the formatting of more-indented lines is preserved.

-}
insFoldNls' :: [Text] -> [Text]
insFoldNls' = go'
  where
    go []                  = []
    go (l:ls)
      | T.null l           = l : go  ls
      | isWhite (T.head l) = l : go' ls
      | otherwise          = "" : l : go  ls

    go' []                 = []
    go' (l:ls)
      | T.null l           = l : go' ls
      | isWhite (T.head l) = l : go' ls
      | otherwise          = l : go ls

    -- @s-white@
    isWhite :: Char -> Bool
    isWhite ' '  = True
    isWhite '\t' = True
    isWhite _    = False
