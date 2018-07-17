{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

module Unison.Parser2 where

import           Control.Monad (void, join)
import           Data.Bifunctor (bimap)
import           Data.List.NonEmpty (NonEmpty(..))
import           Data.Maybe
import qualified Data.Set as Set
import           Data.Text (Text)
import           Data.Typeable (Proxy(..))
import           Text.Megaparsec (ParsecT, ParseError, runParserT)
import qualified Text.Megaparsec as P
import qualified Text.Megaparsec.Char as P
import qualified Unison.Lexer as L
import qualified Unison.UnisonFile as UnisonFile

type PEnv = UnisonFile.CtorLookup

type Parser s a = ParsecT Text s ((->) PEnv) a

type UnisonParser a = Parser Input a

newtype Input = Input { inputStream :: [L.Token] } deriving (Eq, Ord, Show)

type Err s = ParseError (P.Token s) Text

instance P.Stream Input where
  type Token Input = L.Token
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

  take1_ (P.chunkToTokens proxy -> []) = Nothing
  take1_ (P.chunkToTokens proxy -> t:ts) = Just (t, P.tokensToChunk proxy ts)
  take1_ _ = error "Unpossible"

  takeN_ n (P.chunkToTokens proxy -> []) | n > 0 = Nothing
  takeN_ n ts =
    Just
      . join bimap (P.tokensToChunk proxy)
      . splitAt n $ P.chunkToTokens proxy ts

  takeWhile_ p = join bimap (P.tokensToChunk proxy) . span p . inputStream

setPos :: P.SourcePos -> L.Pos -> P.SourcePos
setPos sp lp =
  P.SourcePos (P.sourceName sp) (P.mkPos $ L.line lp) (P.mkPos $ L.column lp)

proxy :: Proxy Input
proxy = Proxy

root :: P.Stream s => Parser s a -> Parser s a
root p = p <* P.eof

run' :: P.Stream s
     => Parser s a
     -> s
     -> String
     -> PEnv
     -> Either (Err s) a
run' p s name = runParserT p name s

run :: P.Stream s
    => Parser s a
    -> s
    -> PEnv
    -> Either (Err s) a
run p s = run' p s ""

queryToken :: (L.Lexeme -> Maybe a) -> UnisonParser a
queryToken f = P.token go Nothing
  where go ((f . L.payload) -> Just s) = Right s
        go x = Left (pure (P.Tokens (x:|[])), Set.empty)


openBlock :: UnisonParser String
openBlock = queryToken getOpen
  where
    getOpen (L.Open s) = Just s
    getOpen _ = Nothing

match :: L.Lexeme -> UnisonParser L.Token
match x = P.satisfy ((==) x . L.payload)

semi :: UnisonParser ()
semi = void $ match L.Semi

closeBlock :: UnisonParser ()
closeBlock = void $ match L.Close

wordyId :: UnisonParser String
wordyId = queryToken getWordy
  where getWordy (L.WordyId s) = Just s
        getWordy _ = Nothing

symbolyId :: UnisonParser String
symbolyId = queryToken getSymboly
  where getSymboly (L.SymbolyId s) = Just s
        getSymboly _ = Nothing

