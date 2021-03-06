{-# LANGUAGE FlexibleContexts, InstanceSigs, GeneralizedNewtypeDeriving,
             RankNTypes, ScopedTypeVariables, TypeFamilies #-}
module Text.Grampa.ContextFree.Parallel (FailureInfo(..), ResultList(..), Parser, fromResultList)
where

import Control.Applicative
import Control.Monad (Monad(..), MonadPlus(..))
import Data.Char (isSpace)
import Data.Functor.Classes (Show1(..))
import Data.Functor.Compose (Compose(..))
import Data.List (nub)
import Data.Monoid (Monoid(mappend, mempty), (<>))
import Data.Monoid.Null (MonoidNull(null))
import Data.Monoid.Factorial (FactorialMonoid)
import Data.Monoid.Textual (TextualMonoid)
import qualified Data.Monoid.Cancellative as Cancellative
import qualified Data.Monoid.Null as Null
import qualified Data.Monoid.Factorial as Factorial
import qualified Data.Monoid.Textual as Textual
import Data.String (fromString)

import qualified Text.Parser.Char
import Text.Parser.Char (CharParsing)
import Text.Parser.Combinators (Parsing(..))
import Text.Parser.LookAhead (LookAheadParsing(..))
import Text.Parser.Token (TokenParsing(someSpace))

import qualified Rank2

import Text.Grampa.Class (MonoidParsing(..), MultiParsing(..), ParseResults, ParseFailure(..))

import Prelude hiding (iterate, null, showList, span, takeWhile)

-- | Parser type for context-free grammars using a parallel parsing algorithm with no result sharing nor left recursion
-- support.
newtype Parser (g :: (* -> *) -> *) s r = Parser{applyParser :: s -> ResultList s r}

data ResultList s r = ResultList ![ResultInfo s r] {-# UNPACK #-} !FailureInfo
data ResultInfo s r = ResultInfo !s !r
data FailureInfo = FailureInfo !Int Int [String] deriving (Eq, Show)

instance (Show s, Show r) => Show (ResultList s r) where
   show (ResultList l f) = "ResultList (" ++ shows l (") (" ++ shows f ")")

instance Show1 (ResultList s) where
   liftShowsPrec _sp showList _prec (ResultList l f) rest = "ResultList " ++ showList (simplify <$> l) (shows f rest)
      where simplify (ResultInfo _ r) = r

instance (Show s, Show r) => Show (ResultInfo s r) where
   show (ResultInfo s r) = "(ResultInfo @" ++ show s ++ " " ++ shows r ")"

instance Functor (ResultInfo s) where
   fmap f (ResultInfo s r) = ResultInfo s (f r)

instance Functor (ResultList s) where
   fmap f (ResultList l failure) = ResultList ((f <$>) <$> l) failure

instance Monoid (ResultList s r) where
   mempty = ResultList [] mempty
   ResultList rl1 f1 `mappend` ResultList rl2 f2 = ResultList (rl1 <> rl2) (f1 <> f2)

instance Monoid FailureInfo where
   mempty = FailureInfo 0 maxBound []
   f1@(FailureInfo s1 pos1 exp1) `mappend` f2@(FailureInfo s2 pos2 exp2)
      | s1 < s2 = f2
      | s1 > s2 = f1
      | otherwise = FailureInfo s1 pos' exp'
      where (pos', exp') | pos1 < pos2 = (pos1, exp1)
                         | pos1 > pos2 = (pos2, exp2)
                         | otherwise = (pos1, exp1 <> exp2)

instance Functor (Parser g s) where
   fmap f (Parser p) = Parser (fmap f . p)

instance Applicative (Parser g s) where
   pure a = Parser (\rest-> ResultList [ResultInfo rest a] mempty)
   Parser p <*> Parser q = Parser r where
      r rest = case p rest
               of ResultList results failure -> ResultList [] failure <> foldMap continue results
      continue (ResultInfo rest' f) = f <$> q rest'


instance FactorialMonoid s => Alternative (Parser g s) where
   empty = Parser (\s-> ResultList [] $ FailureInfo 0 (Factorial.length s) ["empty"])
   Parser p <|> Parser q = Parser r where
      r rest = p rest <> q rest

instance Monad (Parser g s) where
   return = pure
   Parser p >>= f = Parser q where
      q rest = case p rest
               of ResultList results failure -> ResultList [] failure <> foldMap continue results
      continue (ResultInfo rest' a) = applyParser (f a) rest'

instance FactorialMonoid s => MonadPlus (Parser g s) where
   mzero = empty
   mplus = (<|>)

instance Monoid x => Monoid (Parser g s x) where
   mempty = pure mempty
   mappend = liftA2 mappend

-- | Parallel parser produces a list of all possible parses.
--
-- @
-- 'parseComplete' :: ("Rank2".'Rank2.Functor' g, 'FactorialMonoid' s) =>
--                  g (Parallel.'Parser' g s) -> s -> g ('Compose' 'ParseResults' [])
-- @
instance MultiParsing Parser where
   type ResultFunctor Parser = Compose ParseResults []
   -- | Returns the list of all possible input prefix parses paired with the remaining input suffix.
   parsePrefix g input = Rank2.fmap (Compose . Compose . fromResultList input . (`applyParser` input)) g
   -- | Returns the list of all possible parses of complete input.
   parseComplete :: forall g s. (Rank2.Functor g, FactorialMonoid s) =>
                    g (Parser g s) -> s -> g (Compose ParseResults [])
   parseComplete g input = Rank2.fmap ((snd <$>) . getCompose) (parsePrefix (Rank2.fmap (<* endOfInput) g) input)

instance MonoidParsing (Parser g) where
   endOfInput = Parser f
      where f s | null s = ResultList [ResultInfo s ()] mempty
                | otherwise = ResultList [] (FailureInfo 1 (Factorial.length s) ["endOfInput"])
   getInput = Parser p
      where p s = ResultList [ResultInfo mempty s] mempty
   anyToken = Parser p
      where p s = case Factorial.splitPrimePrefix s
                  of Just (first, rest) -> ResultList [ResultInfo rest first] mempty
                     _ -> ResultList [] (FailureInfo 1 (Factorial.length s) ["anyToken"])
   satisfy predicate = Parser p
      where p s = case Factorial.splitPrimePrefix s
                  of Just (first, rest) | predicate first -> ResultList [ResultInfo rest first] mempty
                     _ -> ResultList [] (FailureInfo 1 (Factorial.length s) ["satisfy"])
   satisfyChar predicate = Parser p
      where p s =
               case Textual.splitCharacterPrefix s
               of Just (first, rest) | predicate first -> ResultList [ResultInfo rest first] mempty
                  _ -> ResultList [] (FailureInfo 1 (Factorial.length s) ["satisfyChar"])
   satisfyCharInput predicate = Parser p
      where p s =
               case Textual.splitCharacterPrefix s
               of Just (first, rest) | predicate first -> ResultList [ResultInfo rest $ Factorial.primePrefix s] mempty
                  _ -> ResultList [] (FailureInfo 1 (Factorial.length s) ["satisfyChar"])
   notSatisfy predicate = Parser p
      where p s = case Factorial.splitPrimePrefix s
                  of Just (first, _) 
                        | predicate first -> ResultList [] (FailureInfo 1 (Factorial.length s) ["notSatisfy"])
                     _ -> ResultList [ResultInfo s ()] mempty
   notSatisfyChar predicate = Parser p
      where p s = case Textual.characterPrefix s
                  of Just first 
                        | predicate first -> ResultList [] (FailureInfo 1 (Factorial.length s) ["notSatisfyChar"])
                     _ -> ResultList [ResultInfo s ()] mempty
   scan s0 f = Parser (p s0)
      where p s i = ResultList [ResultInfo suffix prefix] mempty
               where (prefix, suffix, _) = Factorial.spanMaybe' s f i
   scanChars s0 f = Parser (p s0)
      where p s i = ResultList [ResultInfo suffix prefix] mempty
               where (prefix, suffix, _) = Textual.spanMaybe_' s f i
   takeWhile predicate = Parser p
      where p s | (prefix, suffix) <- Factorial.span predicate s = ResultList [ResultInfo suffix prefix] mempty
   takeWhile1 predicate = Parser p
      where p s | (prefix, suffix) <- Factorial.span predicate s = 
               if Null.null prefix
               then ResultList [] (FailureInfo 1 (Factorial.length s) ["takeWhile1"])
               else ResultList [ResultInfo suffix prefix] mempty
   takeCharsWhile predicate = Parser p
      where p s | (prefix, suffix) <- Textual.span_ False predicate s = ResultList [ResultInfo suffix prefix] mempty
   takeCharsWhile1 predicate = Parser p
      where p s | (prefix, suffix) <- Textual.span_ False predicate s =
               if null prefix
               then ResultList [] (FailureInfo 1 (Factorial.length s) ["takeCharsWhile1"])
               else ResultList [ResultInfo suffix prefix] mempty
   string s = Parser p where
      p s' | Just suffix <- Cancellative.stripPrefix s s' = ResultList [ResultInfo suffix s] mempty
           | otherwise = ResultList [] (FailureInfo 1 (Factorial.length s') ["string " ++ show s])
   whiteSpace = () <$ takeCharsWhile isSpace
   concatMany (Parser p) = Parser q
      where q s = ResultList [] failure <> foldMap continue rs
               where ResultList rs failure = p s
            continue (ResultInfo suffix prefix) = (prefix <>) <$> q suffix

instance FactorialMonoid s => Parsing (Parser g s) where
   try (Parser p) = Parser (weakenResults . p)
      where weakenResults (ResultList rl (FailureInfo s pos msgs)) = ResultList rl (FailureInfo (pred s) pos msgs)
   Parser p <?> msg  = Parser (strengthenResults . p)
      where strengthenResults (ResultList rl (FailureInfo s pos _msgs)) = ResultList rl (FailureInfo (succ s) pos [msg])
   notFollowedBy (Parser p) = Parser (\input-> rewind input (p input))
      where rewind t (ResultList [] _) = ResultList [ResultInfo t ()] mempty
            rewind t ResultList{} = ResultList [] (FailureInfo 1 (Factorial.length t) ["notFollowedBy"])
   skipMany p = go
      where go = pure () <|> p *> go
   unexpected msg = Parser (\t-> ResultList [] $ FailureInfo 0 (Factorial.length t) [msg])
   eof = endOfInput

instance FactorialMonoid s => LookAheadParsing (Parser g s) where
   lookAhead (Parser p) = Parser (\input-> rewind input (p input))
      where rewind t (ResultList rl failure) = ResultList (rewindInput t <$> rl) failure
            rewindInput t (ResultInfo _ r) = ResultInfo t r

instance (Show s, TextualMonoid s) => CharParsing (Parser g s) where
   satisfy = satisfyChar
   string s = Textual.toString (error "unexpected non-character") <$> string (fromString s)
   char = satisfyChar . (==)
   notChar = satisfyChar . (/=)
   anyChar = satisfyChar (const True)
   text t = (fromString . Textual.toString (error "unexpected non-character")) <$> string (Textual.fromText t)

instance (Show s, TextualMonoid s) => TokenParsing (Parser g s) where
   someSpace = () <$ takeCharsWhile1 isSpace

fromResultList :: FactorialMonoid s => s -> ResultList s r -> ParseResults [(s, r)]
fromResultList s (ResultList [] (FailureInfo _ pos msgs)) = Left (ParseFailure (Factorial.length s - pos) (nub msgs))
fromResultList _ (ResultList rl _failure) = Right (f <$> rl)
   where f (ResultInfo s r) = (s, r)
