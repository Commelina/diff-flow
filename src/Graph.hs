{-# LANGUAGE GADTs #-}
{-# LANGUAGE RecordWildCards #-}

module Graph where

import Types

import Data.Word (Word64)
import Data.Aeson (Value (..))
import Control.Concurrent.MVar
import Data.Set (Set)
import qualified Data.Set as Set


import Data.Proxy
import qualified Data.HashMap.Lazy as HM
import Data.HashMap.Lazy (HashMap)
import Data.Hashable (Hashable)
import qualified Data.List as L
import Data.Vector (Vector)
import qualified Data.Vector as V

newtype Node = Node { nodeId :: Int } deriving (Eq, Show, Ord)

data NodeInput = NodeInput
  { nodeInputNode :: Node
  , nodeInputIndex :: Int
  } deriving (Eq, Show, Ord)

newtype Mapper = Mapper { mapper :: Row -> Row }
newtype Reducer = Reducer { reducer :: Value -> Row -> Word64 -> Row }

{-
class HasIndex a where
  hasIndex :: Proxy a

class NeedIndex a where
  needIndex :: Proxy a

data NodeSpec a where
  InputSpec :: NodeSpec a
  MapSpec :: Node -> Mapper -> NodeSpec a
  IndexSpec :: (HasIndex a) => Node -> NodeSpec a
  ReduceSpec :: (HasIndex a, NeedIndex a) => Node -> Word64 -> Value -> Reducer -> NodeSpec a
-}

data NodeSpec
  = InputSpec
  | MapSpec           Node Mapper               -- input, mapper
  | IndexSpec         Node                      -- input
  | JoinSpec          Node Node Word64          -- input1, input2, key_columns
  | OutputSpec        Node                      -- input
  | TimestampPushSpec Node                      -- input
  | TimestampIncSpec  (Maybe Node)              -- input
  | TimestampPopSpec  Node                      -- input
  | UnionSpec         Node Node                 -- input1, input2
  | DistinctSpec      Node                      -- input
  | ReduceSpec        Node Word64 Value Reducer -- input, key_columns, init, reducer

outputIndex :: NodeSpec -> Bool
outputIndex (IndexSpec _)        = True
outputIndex (DistinctSpec _)     = True
outputIndex (ReduceSpec _ _ _ _) = True
outputIndex _ = False

needIndex :: NodeSpec -> Bool
needIndex (DistinctSpec _)     = True
needIndex (ReduceSpec _ _ _ _) = True
needIndex _ = False

getInpusFromSpec :: NodeSpec -> Vector Node
getInpusFromSpec InputSpec = V.empty
getInpusFromSpec (MapSpec node _) = V.singleton node
getInpusFromSpec (IndexSpec node) = V.singleton node
getInpusFromSpec (JoinSpec node1 node2 _) = V.fromList [node1, node2]
getInpusFromSpec (OutputSpec node) = V.singleton node
getInpusFromSpec (TimestampPushSpec node) = V.singleton node
getInpusFromSpec (TimestampIncSpec m_node) = case m_node of
                                               Nothing   -> V.empty
                                               Just node -> V.singleton node
getInpusFromSpec (TimestampPopSpec node) = V.singleton node
getInpusFromSpec (UnionSpec node1 node2) = V.fromList [node1, node2]
getInpusFromSpec (DistinctSpec node) = V.singleton node
getInpusFromSpec (ReduceSpec node _ _ _) = V.singleton node


data NodeState a
  = InputState (MVar (Frontier a)) (MVar (DataChangeBatch a))
  | IndexState (MVar (Index a)) (MVar [DataChange a])
  | JoinState (MVar (Frontier a)) (MVar (Frontier a))
  | OutputState (MVar [DataChangeBatch a])
  | DistinctState (MVar (Index a)) (MVar (HashMap Row (Set (Timestamp a))))
  | ReduceState (MVar (Index a)) (MVar (HashMap Row (Set (Timestamp a))))
  | NoState

specToState :: (Show a, Ord a, Hashable a) => NodeSpec -> IO (NodeState a)
specToState InputSpec = do
  frontier <- newMVar Set.empty
  unflushedChanges <- newMVar $ mkDataChangeBatch []
  return $ InputState frontier unflushedChanges
specToState (IndexSpec _) = do
  index <- newMVar $ Index []
  pendingChanges <- newMVar []
  return $ IndexState index pendingChanges
specToState (JoinSpec _ _ _) = do
  frontier1 <- newMVar Set.empty
  frontier2 <- newMVar Set.empty
  return $ JoinState frontier1 frontier2
specToState (OutputSpec _) = do
  unpopedBatches <- newMVar []
  return $ OutputState unpopedBatches
specToState (DistinctSpec _) = do
  index <- newMVar $ Index []
  pendingCorrections <- newMVar HM.empty
  return $ DistinctState index pendingCorrections
specToState (ReduceSpec _ _ _ _) = do
  index <- newMVar $ Index []
  pendingCorrections <- newMVar HM.empty
  return $ ReduceState index pendingCorrections
specToState _ = return NoState


----

newtype Subgraph = Subgraph { subgraphId :: Int } deriving (Eq, Show)

data Graph = Graph
  { graphNodeSpecs :: HashMap Int NodeSpec
  , graphNodeSubgraphs :: HashMap Int [Subgraph]
  , graphSubgraphParents :: HashMap Int Subgraph
  , graphDownstreamNodes :: HashMap Int [NodeInput]
  }

data GraphBuilder = GraphBuilder
  { graphBuilderNodeSpecs :: Vector NodeSpec
  , graphBuilderSubgraphs :: Vector Subgraph
  , graphBuilderSubgraphParents :: Vector Subgraph
  }

addSubgraph :: GraphBuilder -> Subgraph -> (GraphBuilder, Subgraph)
addSubgraph builder@GraphBuilder{..} parent =
  ( builder{ graphBuilderSubgraphParents = V.snoc graphBuilderSubgraphParents parent}
  , Subgraph {subgraphId = V.length graphBuilderSubgraphParents + 1}
  )

addNode :: GraphBuilder -> Subgraph -> NodeSpec -> (GraphBuilder, Node)
addNode builder@GraphBuilder{..} subgraph spec =
  ( builder{ graphBuilderNodeSpecs = V.snoc graphBuilderNodeSpecs spec
           , graphBuilderSubgraphs = V.snoc graphBuilderSubgraphs subgraph}
  , newNode
  )
  where newNode = Node { nodeId = V.length graphBuilderNodeSpecs }

connectLoop :: GraphBuilder -> Node -> Node -> GraphBuilder
connectLoop builder@GraphBuilder{..} later earlier =
  builder{ graphBuilderNodeSpecs =
           case graphBuilderNodeSpecs V.! earlierId of
             TimestampIncSpec _ ->
               V.update graphBuilderNodeSpecs
                 (V.singleton (earlierId, TimestampIncSpec (Just later)))
             _ -> error "connectLoop: the earlier node can only be TimestampInc"
         }
  where earlierId = nodeId earlier

buildGraph :: GraphBuilder -> Graph
buildGraph GraphBuilder{..} =
  if V.length graphBuilderSubgraphs == nodesNum then
    Graph { graphNodeSpecs = nodeSpecs
          , graphNodeSubgraphs = subgraphs
          , graphSubgraphParents = subgraphParents
          , graphDownstreamNodes = downstreamNodes
          }
    else error $ "GraphBuilder: NodeSpecs and Subgraphs have different length: "
               <> show nodesNum <> ", " <> show (V.length graphBuilderSubgraphs)
  where
    nodesNum = V.length graphBuilderNodeSpecs
    nodeSpecs = V.ifoldl (\acc i x -> HM.insert i x acc) HM.empty graphBuilderNodeSpecs
    findSubgraphs :: Subgraph -> [Subgraph]
    findSubgraphs immSubgraph
      | immId == 0 = []
      | otherwise = immSubgraph:findSubgraphs (graphBuilderSubgraphParents V.! (immId - 1))
      where immId = subgraphId immSubgraph
    subgraphs = V.ifoldl (\acc i x ->
                                 HM.insert i (findSubgraphs x) acc)
                     HM.empty graphBuilderSubgraphs
    downstreamNodes = V.ifoldl (\acc i x ->
                                 V.ifoldl (\acc' i' x' ->
                                             let nodeInput = NodeInput (Node i) i'
                                              in HM.adjust (nodeInput :) (nodeId x') acc'
                                          ) acc (getInpusFromSpec x)
                               )
                      (V.ifoldl (\acc i x -> HM.insert i [] acc) HM.empty  graphBuilderNodeSpecs)
                      graphBuilderNodeSpecs
    subgraphParents = V.ifoldl (\acc i x -> HM.insert i x acc) HM.empty graphBuilderSubgraphParents
