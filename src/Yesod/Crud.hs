module Yesod.Crud where

import Prelude
import Control.Applicative
import Data.Maybe

import Lens.Micro.TH

import Yesod.Core
import Database.Persist(Key)
import Network.Wai (pathInfo, requestMethod)
import qualified Data.List as List
import Yesod.Persist
import Database.Persist.Sql
import Data.Foldable (for_)

import Yesod.Crud.Internal

-- In Crud, c is the child type, and p is the type of the identifier
-- for its parent.
data Crud master p c = Crud
  { _ccAdd    :: p -> HandlerT (Crud master p c) (HandlerT master IO) Html
  , _ccIndex  :: p -> HandlerT (Crud master p c) (HandlerT master IO) Html
  , _ccEdit   :: Key c -> HandlerT (Crud master p c) (HandlerT master IO) Html
  , _ccDelete :: Key c -> HandlerT (Crud master p c) (HandlerT master IO) Html
  }
makeLenses ''Crud

-- Dispatch for the child crud subsite
instance (Eq (Key c), PathPiece (Key c), Eq p, PathPiece p) => YesodSubDispatch (Crud master p c) (HandlerT master IO) where
  yesodSubDispatch env req = h
    where 
    h = let parsed = parseRoute (pathInfo req, []) 
            helper a = subHelper (fmap toTypedContent a) env parsed req
        in case parsed of
          Just (EditR theId)   -> onlyAllow ["GET","POST"]
            $ helper $ getYesod >>= (\s -> _ccEdit s theId)
          Just (DeleteR theId) -> onlyAllow ["GET","POST"] 
            $ helper $ getYesod >>= (\s -> _ccDelete s theId)
          Just (AddR p) -> onlyAllow ["GET","POST"] 
            $ helper $ getYesod >>= (\s -> _ccAdd s p)
          Just (IndexR p) -> onlyAllow ["GET"] 
            $ helper $ getYesod >>= (\s -> _ccIndex s p)
          Nothing              -> notFoundApp
    onlyAllow reqTypes waiApp = if isJust (List.find (== requestMethod req) reqTypes) then waiApp else notFoundApp
    notFoundApp = subHelper (fmap toTypedContent notFoundUnit) env Nothing req
    notFoundUnit = fmap (\() -> ()) notFound

instance (PathPiece (Key c), Eq (Key c), PathPiece p, Eq p) => RenderRoute (Crud master p c) where
  data Route (Crud master p c)
    = EditR (Key c)
    | DeleteR (Key c)
    | IndexR p
    | AddR p
  renderRoute r = noParams $ case r of
    EditR theId   -> ["edit",   toPathPiece theId]
    DeleteR theId -> ["delete", toPathPiece theId]
    IndexR p      -> ["index",  toPathPiece p]
    AddR p        -> ["add",    toPathPiece p]
    where noParams xs = (xs,[])

instance (PathPiece (Key c), Eq (Key c), PathPiece p, Eq p) => ParseRoute (Crud master p c) where
  parseRoute (_, (_:_)) = Nothing
  parseRoute (xs, []) = Nothing
    <|> (runSM xs $ pure EditR <* consumeMatchingText "edit" <*> consumeKey)
    <|> (runSM xs $ pure DeleteR <* consumeMatchingText "delete" <*> consumeKey)
    <|> (runSM xs $ pure IndexR <* consumeMatchingText "index" <*> consumeKey)
    <|> (runSM xs $ pure AddR <* consumeMatchingText "add" <*> consumeKey)

deriving instance (Eq (Key c), Eq p) => Eq (Route (Crud master p c))
deriving instance (Show (Key c), Show p) => Show (Route (Crud master p c))
deriving instance (Read (Key c), Read p) => Read (Route (Crud master p c))

type HierarchyCrud master a = Crud master (Maybe (Key a)) a

class (NodeTable c ~ a, ClosureTable a ~ c) => ClosureTablePair a c where
  type NodeTable c
  type ClosureTable a
  closureAncestorCol :: EntityField c (Key a)
  closureDescendantCol :: EntityField c (Key a)
  closureDepthCol :: EntityField c Int
  closureAncestor :: c -> Key a
  closureDescendant :: c -> Key a
  closureDepth :: c -> Int
  closureCreate :: Key a -> Key a -> Int -> c

type PersistCrudEntity master a =
  ( PathPiece (Key a) 
  , Yesod master
  , YesodPersist master
  , PersistEntity a
  , PersistQuery (YesodPersistBackend master)
  , PersistEntityBackend a ~ YesodPersistBackend master
  )

type SqlClosure a c = 
  ( ClosureTablePair a c
  , PersistEntityBackend a ~ SqlBackend
  , PersistEntityBackend (ClosureTable a) ~ SqlBackend
  , PersistEntity a
  , PersistEntity c
  , PersistField (Key a)
  )

closureDepthColAs :: forall a c. ClosureTablePair a c 
  => Key a -> EntityField c Int
closureDepthColAs _ = (closureDepthCol :: EntityField c Int)

-- This includes the child itself, the root comes first
closureGetParents :: (MonadIO m, SqlClosure a c) => Key a -> SqlPersistT m [Entity a]
closureGetParents theId = do
  cs <- selectList [closureDescendantCol ==. theId] [Desc closureDepthCol]
  selectList [persistIdField <-. map (closureAncestor . entityVal) cs] []

closureGetImmidiateChildren :: (MonadIO m, SqlClosure a c) 
   => Key a -> SqlPersistT m [Entity a]
closureGetImmidiateChildren theId = do
  cs <- selectList [closureAncestorCol ==. theId, closureDepthCol ==. 1] []
  selectList [persistIdField <-. map (closureDescendant . entityVal) cs] [Asc persistIdField]

closureGetParentId :: (MonadIO m, SqlClosure a c) 
   => Key a -> SqlPersistT m (Maybe (Key a))
closureGetParentId theId = do
  cs <- selectList [closureDescendantCol ==. theId, closureDepthCol ==. 1] []
  return $ fmap (closureAncestor . entityVal) $ listToMaybe cs

closureGetParentIdProxied :: (MonadIO m, SqlClosure a c) 
   => p c -> Key a -> SqlPersistT m (Maybe (Key a))
closureGetParentIdProxied _ = closureGetParentId

closureInsert :: forall m a c. (MonadIO m, SqlClosure a c) 
  => Maybe (Key a) -> a -> SqlPersistT m (Key a)
closureInsert mparent a = do
  childId <- insert a
  _ <- insert $ closureCreate childId childId 0 
  for_ mparent $ \parentId -> do
    cs <- selectList [closureDescendantCol ==. parentId] []
    insertMany_ $ map (\(Entity _ c) -> 
      closureCreate (closureAncestor c) childId (closureDepth c + 1)) cs 
  return childId

closureRootNodes :: (MonadIO m, SqlClosure a c) => SqlPersistT m [Entity a]
closureRootNodes = error "Write this" -- probably with esqueleto

