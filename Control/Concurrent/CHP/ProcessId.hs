-- Communicating Haskell Processes.
-- Copyright (c) 2008, University of Kent.
-- All rights reserved.
-- 
-- Redistribution and use in source and binary forms, with or without
-- modification, are permitted provided that the following conditions are
-- met:
--
--  * Redistributions of source code must retain the above copyright
--    notice, this list of conditions and the following disclaimer.
--  * Redistributions in binary form must reproduce the above copyright
--    notice, this list of conditions and the following disclaimer in the
--    documentation and/or other materials provided with the distribution.
--  * Neither the name of the University of Kent nor the names of its
--    contributors may be used to endorse or promote products derived from
--    this software without specific prior written permission.
--
-- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
-- IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
-- THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
-- PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
-- CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
-- EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
-- PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
-- PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
-- LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
-- NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
-- SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

module Control.Concurrent.CHP.ProcessId where

-- We derive Ord for these two types so that they can be used in sets.  However,
-- the Ord instance should not be confused with the partial ordering detailed
-- in the tracing paper, which is provided by the pidLessThanOrEqual function
-- below.

data ProcessIdPart = ParSeq Int Integer deriving (Eq, Ord, Show)

newtype ProcessId = ProcessId [ProcessIdPart] deriving (Eq, Ord, Show)

rootProcessId :: ProcessId
rootProcessId = ProcessId [ParSeq 0 0]

emptyProcessId :: ProcessId
emptyProcessId = ProcessId []

testProcessId :: Int -> ProcessId
testProcessId n = ProcessId [ParSeq n 0]

-- We use here the property that the lists will either be equal, or different
-- within their shared length.  Therefore they will be different when zipped,
-- or if they're identical that means the originals were identical
pidLessThanOrEqual :: ProcessId -> ProcessId -> Bool
pidLessThanOrEqual (ProcessId pida) (ProcessId pidb) = cmp (zip pida pidb)
    where
      cmp :: ([(ProcessIdPart, ProcessIdPart)]) -> Bool
      cmp [] = True -- Equal
      cmp ((ParSeq pa sa, ParSeq pb sb):xs)
        | pa /= pb  = False -- No ordering
        | sa < sb   = True -- Less than
        | sa > sb   = False -- Greater than
        | otherwise = cmp xs --Both parts equal, keep going
