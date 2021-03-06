{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies      #-}
{-# LANGUAGE ViewPatterns      #-}
{-# LANGUAGE DoAndIfThenElse   #-}

module Unison.Parser where

import           Data.Bytes.Put                 (runPutS)
import           Data.Bytes.Serial              ( serialize )
import           Data.Bytes.VarInt              ( VarInt(..) )
import           Control.Applicative
import           Control.Monad        (join, when)
import           Data.Bifunctor       (bimap)
import qualified Data.Char            as Char
import           Data.List.NonEmpty   (NonEmpty (..))
import           Data.Maybe
import qualified Data.Set             as Set
import           Data.Text            (Text)
import qualified Data.Text            as Text
import           Data.Text.Encoding   (encodeUtf8)
import           Data.Typeable        (Proxy (..))
import           Debug.Trace
import           Text.Megaparsec      (runParserT)
import qualified Text.Megaparsec      as P
import qualified Text.Megaparsec.Char as P
import qualified Unison.ABT           as ABT
import           Unison.Hash
import qualified Unison.Hash          as Hash
import qualified Unison.Lexer         as L
import           Unison.Pattern       (PatternP)
import qualified Unison.PatternP      as Pattern
import           Unison.Term          (MatchCase (..))
import           Unison.Var           (Var)
import qualified Unison.Var           as Var
import qualified Unison.UnisonFile    as UF
import Unison.Names (Names)
import Control.Monad.Reader.Class (ask)
import qualified Crypto.Random as Random
import qualified Unison.Hashable as Hashable

debug :: Bool
debug = False

type P v = P.ParsecT (Error v) Input ((->) (UniqueName, Names))
type Token s = P.Token s
type Err v = P.ParseError (Token Input) (Error v)

newtype UniqueName = UniqueName (L.Pos -> Int -> Maybe Text)

instance Semigroup UniqueName where (<>) = mappend
instance Monoid UniqueName where
  mempty = UniqueName (\_ _ -> Nothing)
  mappend (UniqueName f) (UniqueName g) =
    UniqueName $ \pos len -> f pos len <|> g pos len

uniqueBase58Namegen :: IO UniqueName
uniqueBase58Namegen = do
  rng <- Random.getSystemDRG
  pure . UniqueName $ \pos lenInBase58 -> go pos lenInBase58 rng
  where
  -- if the identifier starts with a number, try again, since
  -- we want the name to work as a valid wordyId
  go pos lenInBase58 rng0 = let
    (bytes,rng) = Random.randomBytesGenerate 32 rng0
    posBytes = runPutS $ do
      serialize $ VarInt (L.line pos)
      serialize $ VarInt (L.column pos)
    h = Hashable.accumulate' $ bytes <> posBytes
    b58 = Hash.base58 h
    in if Char.isDigit (Text.head b58) then go pos lenInBase58 rng
       else Just . Text.take lenInBase58 $ b58

uniqueName :: Var v => Int -> P v Text
uniqueName lenInBase58 = do
  (UniqueName mkName, _) <- ask
  pos <- L.start <$> P.lookAhead anyToken
  let none = Hash.base58 . Hash.fromBytes . encodeUtf8 . Text.pack $ show pos
  pure . fromMaybe none $ mkName pos lenInBase58

data Error v
  = SignatureNeedsAccompanyingBody (L.Token v)
  | EmptyBlock (L.Token String)
  | UnknownAbilityConstructor (L.Token String)
  | UnknownDataConstructor (L.Token String)
  | ExpectedBlockOpen String (L.Token L.Lexeme)
  | EmptyWatch
  | DidntExpectExpression (L.Token L.Lexeme) (Maybe (L.Token L.Lexeme))
  | TypeDeclarationErrors [UF.Error v Ann]
  | DuplicateTypeNames [(v, [Ann])]
  deriving (Show, Eq, Ord)

data Ann
  = Intrinsic -- { sig :: String, start :: L.Pos, end :: L.Pos }
  | External
  | Ann { start :: L.Pos, end :: L.Pos }
  deriving (Eq, Ord, Show)

startingLine :: Ann -> Maybe L.Line
startingLine (Ann (L.line -> line) _) = Just line
startingLine _ = Nothing

endingLine :: Ann -> Maybe L.Line
endingLine (Ann _ (L.line -> line)) = Just line
endingLine _ = Nothing

instance Monoid Ann where
  mempty = External
  mappend = (<>)

instance Semigroup Ann where
  Ann s1 _ <> Ann _ e2 = Ann s1 e2
  -- If we have a concrete location from a file, use it
  External <> a = a
  a <> External = a
  Intrinsic <> a = a
  a <> Intrinsic = a

tokenToPair :: L.Token a -> (Ann, a)
tokenToPair t = (ann t, L.payload t)

newtype Input = Input { inputStream :: [L.Token L.Lexeme] }
  deriving (Eq, Ord, Show)

instance P.Stream Input where
  type Token Input = L.Token L.Lexeme
  type Tokens Input = Input

  tokenToChunk pxy = P.tokensToChunk pxy . pure

  tokensToChunk _ = Input

  chunkToTokens _ = inputStream

  chunkLength pxy = length . P.chunkToTokens pxy

  chunkEmpty pxy = null . P.chunkToTokens pxy

  positionAt1 _ sp t = setPos sp (L.start t)

  positionAtN pxy sp =
    fromMaybe sp . fmap (setPos sp . L.start) . listToMaybe . P.chunkToTokens pxy

  advance1 _ _ cp = setPos cp . L.end

  advanceN _ _ cp = setPos cp . L.end . last . inputStream

  take1_ (P.chunkToTokens proxy -> [])   = Nothing
  take1_ (P.chunkToTokens proxy -> t:ts) = Just (t, P.tokensToChunk proxy ts)
  take1_ _                               = error "Unpossible"

  takeN_ n (P.chunkToTokens proxy -> []) | n > 0 = Nothing
  takeN_ n ts =
    Just
      . join bimap (P.tokensToChunk proxy)
      . splitAt n $ P.chunkToTokens proxy ts

  takeWhile_ p = join bimap (P.tokensToChunk proxy) . span p . inputStream

setPos :: P.SourcePos -> L.Pos -> P.SourcePos
setPos sp lp =
  P.SourcePos (P.sourceName sp) (P.mkPos $ L.line lp) (P.mkPos $ L.column lp)

class Annotated a where
  ann :: a -> Ann

instance Annotated Ann where
  ann = id

instance Annotated (L.Token a) where
  ann (L.Token _ s e) = Ann s e

instance Annotated a => Annotated (ABT.Term f v a) where
  ann = ann . ABT.annotation

instance Annotated a => Annotated (PatternP a) where
  ann = ann . Pattern.loc

instance (Annotated a, Annotated b) => Annotated (MatchCase a b) where
  ann (MatchCase p _ b) = ann p <> ann b

label :: (Var v, Show a) => String -> P v a -> P v a
label = P.label
-- label = P.dbg

traceRemainingTokens :: Var v => String -> P v ()
traceRemainingTokens label = do
  remainingTokens <- lookAhead $ many anyToken
  let _ = trace ("REMAINDER " ++ label ++ ":\n" ++ L.debugLex'' remainingTokens) ()
  pure ()

mkAnn :: (Annotated a, Annotated b) => a -> b -> Ann
mkAnn x y = ann x <> ann y

showLineCol :: Annotated a => a -> String
showLineCol a =
  let L.Pos line col = start $ ann a
  in "Line " ++ show line ++ ", column " ++ show col

tok :: (Ann -> a -> b) -> L.Token a -> b
tok f (L.Token a start end) = f (Ann start end) a

peekAny :: Var v => P v (L.Token L.Lexeme)
peekAny = P.lookAhead P.anyChar

lookAhead :: Var v => P v a -> P v a
lookAhead = P.lookAhead

anyToken :: Var v => P v (L.Token L.Lexeme)
anyToken = P.anyChar

proxy :: Proxy Input
proxy = Proxy

root :: Var v => P v a -> P v a
root p = (openBlock *> p) <* closeBlock <* P.eof

-- |
rootFile :: Var v => P v a -> P v a
rootFile p = p <* P.eof

type ParsingEnv = (UniqueName, Names)

run' :: Var v => P v a -> String -> String -> ParsingEnv -> Either (Err v) a
run' p s name =
  let lex = if debug
            then L.lexer name (trace (L.debugLex''' "lexer receives" s) s)
            else L.lexer name s
      pTraced = traceRemainingTokens "parser receives" *> p
  in runParserT pTraced name (Input lex)

run :: Var v => P v a -> String -> ParsingEnv -> Either (Err v) a
run p s = run' p s ""

-- Virtual pattern match on a lexeme.
queryToken :: Var v => (L.Lexeme -> Maybe a) -> P v (L.Token a)
queryToken f = P.token go Nothing
  where go t@((f . L.payload) -> Just s) = Right $ fmap (const s) t
        go x = Left (pure (P.Tokens (x:|[])), Set.empty)

currentLine :: Var v => P v (Int, String)
currentLine = P.lookAhead $ do
  tok0 <- P.satisfy (const True)
  let line0 = L.line (L.start tok0)
  toks <- many $ P.satisfy (\t -> L.line (L.start t) == line0)
  let lineToks = tok0 Data.List.NonEmpty.:|  toks
  pure (line0, P.showTokens lineToks)

-- Consume a block opening and return the string that opens the block.
openBlock :: Var v => P v (L.Token String)
openBlock = queryToken getOpen
  where
    getOpen (L.Open s) = Just s
    getOpen _          = Nothing

openBlockWith :: Var v => String -> P v (L.Token ())
openBlockWith s = fmap (const ()) <$> P.satisfy ((L.Open s ==) . L.payload)

-- Match a particular lexeme exactly, and consume it.
matchToken :: Var v => L.Lexeme -> P v (L.Token L.Lexeme)
matchToken x = P.satisfy ((==) x . L.payload)

dot :: Var v => P v (L.Token L.Lexeme)
dot = matchToken (L.SymbolyId ".")

-- Consume a virtual semicolon
semi :: Var v => P v (L.Token ())
semi = fmap (const ()) <$> matchToken L.Semi

-- Consume the end of a block
closeBlock :: Var v => P v (L.Token ())
closeBlock = fmap (const ()) <$> matchToken L.Close

-- Parse an alphanumeric identifier
wordyId :: Var v => P v (L.Token String)
wordyId = queryToken getWordy
  where getWordy (L.WordyId s) = Just s
        getWordy _             = Nothing

-- Parse a specific wordy id
exactWordyId :: Var v => String -> P v (L.Token String)
exactWordyId target = queryToken getWordy
  where getWordy (L.WordyId s) | s == target = Just s
        getWordy _                           = Nothing

-- Parse a symboly ID like >>= or &&
symbolyId :: Var v => P v (L.Token String)
symbolyId = queryToken getSymboly
  where getSymboly (L.SymbolyId s) = Just s
        getSymboly _               = Nothing

backticks :: Var v => P v (L.Token String)
backticks = queryToken getBackticks
  where getBackticks (L.Backticks s) = Just s
        getBackticks _               = Nothing

-- Parse a reserved word
reserved :: Var v => String -> P v (L.Token String)
reserved w = label w $ queryToken getReserved
  where getReserved (L.Reserved w') | w == w' = Just w
        getReserved _               = Nothing

-- Parse a placeholder or typed hole
blank :: Var v => P v (L.Token String)
blank = label "blank" $ queryToken getBlank
  where getBlank (L.Blank s) = Just ('_' : s)
        getBlank _           = Nothing

numeric :: Var v => P v (L.Token String)
numeric = queryToken getNumeric
  where getNumeric (L.Numeric s) = Just s
        getNumeric _             = Nothing

sepComma :: Var v => P v a -> P v [a]
sepComma = sepBy (reserved ",")

sepBy :: Var v => P v a -> P v b -> P v [b]
sepBy sep pb = P.sepBy pb sep

sepBy1 :: Var v => P v a -> P v b -> P v [b]
sepBy1 sep pb = P.sepBy1 pb sep

prefixVar :: Var v => P v (L.Token v)
prefixVar = fmap (Var.named . Text.pack) <$> label "symbol" prefixOp
  where
    prefixOp = blank <|> wordyId <|> label "prefix-operator" (P.try (openBlockWith "(" *> symbolyId) <* closeBlock)

infixVar :: Var v => P v (L.Token v)
infixVar =
  fmap (Var.named . Text.pack) <$> (symbolyId <|> backticks)

hashLiteral :: Var v => P v (L.Token Hash)
hashLiteral = queryToken getHash
  where getHash (L.Hash s) = Just s
        getHash _          = Nothing

string :: Var v => P v (L.Token Text)
string = queryToken getString
  where getString (L.Textual s) = Just (Text.pack s)
        getString _             = Nothing

tupleOrParenthesized :: Var v => P v a -> (Ann -> a) -> (a -> a -> a) -> P v a
tupleOrParenthesized p unit pair = do
    open <- openBlockWith "("
    es <- sepBy (reserved "," *> optional semi) p
    close <- optional semi *> closeBlock
    pure $ go es open close
  where
    go [t] _ _ = t
    go as s e  = foldr pair (unit (ann s <> ann e)) as

seq :: Var v => (Ann -> [a] -> a) -> P v a -> P v a
seq f p = f' <$> reserved "[" <*> elements <*> trailing
  where
    f' open elems close = f (ann open <> ann close) elems
    trailing = optional semi *> reserved "]"
    sep = P.try $ optional semi *> reserved "," <* optional semi
    elements = sepBy sep p

chainr1 :: Var v => P v a -> P v (a -> a -> a) -> P v a
chainr1 p op = go1 where
  go1 = p >>= go2
  go2 hd = do { op <- op; tl <- go1; pure $ op hd tl } <|> pure hd

-- Parse `p` 1+ times, combining with `op`
chainl1 :: Var v => P v a -> P v (a -> a -> a) -> P v a
chainl1 p op = foldl (flip ($)) <$> p <*> P.many (flip <$> op <*> p)

attempt :: Var v => P v a -> P v a
attempt = P.try

-- If `p` would succeed, this fails uncommitted.
-- Otherwise, `failIfOk` is used to produce
failureIf :: Var v => P v (P v b) -> P v a -> P v b
failureIf failIfOk p = do
  dontwant <- P.try . P.lookAhead $ failIfOk
  p <- P.try $ P.lookAhead (optional p)
  when (isJust p) $ fail "failureIf"
  dontwant

-- Gives this var an id based on its position - a useful trick to
-- obtain a variable whose id won't match any other id in the file
-- `positionalVar a Var.missingResult`
positionalVar :: (Annotated a, Var v) => a -> v -> v
positionalVar a v =
  let s = start (ann a)
      line = fromIntegral $ L.line s
      col = fromIntegral $ L.column s
  -- this works as long as no lines more than 50k characters
  in Var.freshenId (line * 50000 + col) v
