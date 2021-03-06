{-# OPTIONS_GHC -fno-warn-unused-imports #-}
{-# OPTIONS_GHC -fno-warn-unused-binds #-} -- todo: remove me later
{-# LANGUAGE FunctionalDependencies #-}

module Unison.Codebase.Classes (GetDecls, PutDecls, GetBranch, PutBranch, getTerm, getTypeOfTerm, getTypeDeclaration, putTerm, putTypeDeclarationImpl, getRootBranch, putRootBranch) where

import           Unison.Codebase.Branch2         ( Branch )
import qualified Unison.Reference              as Reference
import           Unison.Reference               ( Reference )
import qualified Unison.Term                   as Term
import qualified Unison.Type                   as Type
import qualified Unison.Typechecker.TypeLookup as TL

type Term v a = Term.AnnotatedTerm v a
type Type v a = Type.AnnotatedType v a
type Decl v a = TL.Decl v a

class GetDecls d m v a | d -> m v a where
  getTerm            :: d -> Reference.Id -> m (Maybe (Term v a))
  getTypeOfTerm      :: d -> Reference -> m (Maybe (Type v a))
  getTypeDeclaration :: d -> Reference.Id -> m (Maybe (Decl v a))

class PutDecls d m v a | d -> m v a where
  putTerm                :: d -> Reference.Id -> Term v a -> Type v a -> m ()
  putTypeDeclarationImpl :: d -> Reference.Id -> Decl v a -> m ()

class GetBranch b m | b -> m where
  getRootBranch :: b -> m [Branch m]

class PutBranch b m | b -> m where
  putRootBranch :: b -> Branch m -> m ()
