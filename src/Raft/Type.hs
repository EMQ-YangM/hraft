{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Raft.Type where

import Codec.Serialise
import Control.Concurrent.Class.MonadSTM
import Control.DeepSeq (NFData)
import Control.Monad.Class.MonadTime
import Control.Monad.Class.MonadTimer
import Control.Tracer
import Data.Map (Map)
import Data.Time
import GHC.Generics

newtype NodeId = NodeId Int deriving (Eq, Ord, Generic, NFData)

instance Show NodeId where
  show (NodeId i) = show i

unNodeId :: NodeId -> Int
unNodeId (NodeId i) = i

newtype PeerNodeId = PeerNodeId Int deriving (Show, Eq, Ord, Generic, NFData)

unPeerNodeId :: PeerNodeId -> Int
unPeerNodeId (PeerNodeId i) = i

type Term = Int

type Id = Int

type Index = Int

data TermWarpper log = TermWarpper Term log deriving (Eq, Ord, Generic, Serialise, NFData)

instance Show log => Show (TermWarpper log) where
  show (TermWarpper t log') = show t ++ "-" ++ show log'

--------------- RPC message
data AppendEntries s = AppendEntries
  { term :: Term,
    leaderId :: Id,
    prevLogIndex :: Index,
    prevLogTerm :: Term,
    entries :: [TermWarpper s],
    leaderCommit :: Index
  }
  deriving (Generic, Serialise, Eq, Show, NFData)

data AppendEntriesResult = AppendEntriesResult
  { term :: Term,
    success :: Bool
  }
  deriving (Generic, Eq, Serialise, Show, NFData)

data RequestVote = RequestVote
  { term :: Term,
    candidateId :: Id,
    lastLogIndex :: Index,
    lastLogTerm :: Term
  }
  deriving (Generic, Eq, Serialise, Show, NFData)

data RequestVoteResult = RequestVoteResult
  { term :: Term,
    voteGranted :: Bool
  }
  deriving (Generic, Eq, Serialise, Show, NFData)

data Msg s
  = MsgAppendEntries (AppendEntries s)
  | MsgAppendEntriesResult AppendEntriesResult
  | MsgRequestVote RequestVote
  | MsgRequestVoteResult RequestVoteResult
  deriving (Generic, Eq, Serialise, Show, NFData)

data PersistentFun log m = PersistentFun
  { readCurrentTerm :: m Term,
    writeCurrentTerm :: Term -> m (),
    --------
    readVotedFor :: m (Maybe Id),
    writeVotedFor :: Maybe Id -> m (),
    ---------
    appendLog :: TermWarpper log -> m Index,
    readLog :: Index -> m (TermWarpper log),
    readLogs :: Index -> Index -> m [TermWarpper log],
    removeLogs :: Index -> m (),
    persisLastLogIndexAndTerm :: m (Index, Term),
    getAllLogs :: m [TermWarpper log],
    ---------
    checkAppendentries :: Index -> Term -> m Bool,
    checkEntry :: Index -> Term -> m CheckEntry
  }

data CheckEntry
  = Exis
  | Diff
  | Null
  deriving (Eq, Show, Generic, NFData)

type CommitIndexTVar m = TVar m Index

type MatchIndexTVar m = TVar m Index

type CmdQueue m = TQueue m Cmd

data Cmd = Terminate

type RecvQueue s m = TQueue m (PeerNodeId, Msg s)

type LastAppliedTVar m = TVar m Index

type ApplyFun state operate m =
  state -> operate -> m state

type LogReader m operate = Index -> Index -> m [TermWarpper operate]

newtype PeerInfo s m = PeerInfo
  { peerSendFun :: Msg s -> m ()
  }

type LastLogIndexTVar m = TVar m Index

type Length = Int

data HEnv s n = HEnv
  { nodeId :: NodeId,
    userLogQueue :: TQueue n s,
    peersRecvQueue :: RecvQueue s n,
    persistentFun :: PersistentFun s n,
    peerInfos :: Map PeerNodeId (PeerInfo s n),
    electionTimeRange :: (DiffTime, DiffTime),
    appendEntriesRpcRetryWaitTime :: DiffTime,
    heartbeatWaitTime :: DiffTime,
    commitIndexTVar :: CommitIndexTVar n,
    lastAppliedTVar :: LastAppliedTVar n,
    tracer :: Tracer n (HandleTracer s)
  }

data HState s n = HState
  { electionSize :: DiffTime,
    electionTimeout :: Timeout n
  }

data SState = SState
  { syncingPrevLogIndex :: Index,
    syncingLogLength :: Length
  }

data SEnv s n = SEnv
  { nodeId :: NodeId,
    sendFun :: Msg s -> n (),
    currentTerm :: Term,
    persistentFun :: PersistentFun s n,
    appendEntriesRpcRetryWaitTime :: DiffTime,
    heartbeatWaitTime :: DiffTime,
    appendEntriesResultQueue :: TQueue n (Either Cmd AppendEntriesResult),
    matchIndexTVar :: MatchIndexTVar n,
    lastLogIndexTVar :: LastLogIndexTVar n,
    commitIndexTVar :: CommitIndexTVar n,
    tracer :: Tracer n (HandleTracer s)
  }

data LastLogIndexGTSyncingParams = LastLogIndexGTSyncingParams

data HandleTracer' s
  = FollowerTimeoutToCandidate
  | FollowerRecvMsg (PeerNodeId, Msg s)
  | FollowerCheckPrevLog Bool
  | FollowerUpdateCommitIndex Index Index Index
  | CandidateNewElectionStart Term
  | CandidateSetNewElectionSzie DiffTime
  | CandidateSendVotoForMsgToAll [PeerNodeId]
  | CandidateRecvMsg (PeerNodeId, Msg s)
  | CandidateElectionSuccess [PeerNodeId] Term
  | CandidateElectionFailed [PeerNodeId] Term
  | CandidateElectionTimeout
  | VotedForNode Id Term
  | LeaderSendEmptyAppendEntries [PeerNodeId]
  | LeaderRecvPastAppendEntries (AppendEntries s)
  | LeaderRecvPastRequestVote RequestVote
  | LeaderToFollowerAtAP
  | LeaderToFollowerAtRV
  | LeaderStartSyncThread NodeId
  | LeaderRecvMsg (PeerNodeId, Msg s)
  deriving (Eq, Show, Generic, NFData)

type HandleTracer s = TimeWrapper (HandleTracer' s)

type RecvTracer s = TimeWrapper (Msg s)

data TimeWrapper a = TimeWrapper UTCTime a deriving (Eq, Generic, NFData)

instance Show a => Show (TimeWrapper a) where
  show (TimeWrapper t a) =
    let s = formatTime defaultTimeLocale "%S%Q" t
        len = length s
        s' =
          if len < 7
            then s ++ replicate (7 - len) ' '
            else take 7 s
     in s' ++ " " ++ show a