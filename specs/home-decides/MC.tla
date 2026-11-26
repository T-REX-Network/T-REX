------------------------------- MODULE MC -------------------------------
(***************************************************************************)
(* Scenario data for HDCore: wallets, identities, requests and the named   *)
(* values runs.py substitutes into the .cfg files with `<-`, plus          *)
(* reachability probes. A probe is an invariant expected to be VIOLATED:   *)
(* the violation shows the outcome is reachable, so the run is not vacuous.*)
(***************************************************************************)
EXTENDS HDCore

\* Wallets: Alice@A, Carol@A, Bob@A, Bob@B, Bob at home.
\* aI, cI, bI: each identity's own contract, a home wallet (r50's last resort).
W_ALL == {"aA", "cA", "bA", "bB", "bH", "aI", "cI", "bI"}
WC == [w \in W_ALL |-> CASE w \in {"aA", "cA", "bA"} -> "A" [] w = "bB" -> "B" [] OTHER -> "H"]
OWN == [w \in W_ALL |-> CASE w \in {"aA", "aI"} -> "alice" [] w \in {"cA", "cI"} -> "carol" [] OTHER -> "bob"]
IDW == [i \in {"alice", "bob", "carol"} |-> CASE i = "alice" -> "aI" [] i = "carol" -> "cI" [] OTHER -> "bI"]
IDS == {"alice", "bob", "carol"}
BAL == [w \in W_ALL |-> CASE w = "aA" -> 2 [] w = "cA" -> 2 [] OTHER -> 0]
BAL_B2 == [w \in W_ALL |-> CASE w = "aA" -> 2 [] w = "bA" -> 2 [] OTHER -> 0]   \* Bob holds 2 on A
CHAINS == {"A", "B"}
BAL_NAT == [w \in W_ALL |-> CASE w = "aA" -> 2 [] w = "cA" -> 2 [] w = "bH" -> 2 [] OTHER -> 0]
ZERO_C == [c \in CHAINS |-> 0]
WTD_B2 == [c \in CHAINS |-> IF c = "B" THEN 2 ELSE 0]     \* B waits two units longer than A
WTD_A2 == [c \in CHAINS |-> IF c = "A" THEN 2 ELSE 0]
LATD_B1 == [c \in CHAINS |-> IF c = "B" THEN 1 ELSE 0]
UNVER_BB == {"bB"}
UNVER_BA == {"bA"}
UNVER_BH == {"bH"}
CH_A == {"A"}
CH_B == {"B"}
CH_AB == {"A", "B"}

\* Bob's cap: 3 lets one ticket of 2 through and narrows a second one to 1.
CAP3 == [i \in IDS |-> IF i = "bob" THEN 3 ELSE 100]
CAP1 == [i \in IDS |-> IF i = "bob" THEN 1 ELSE 100]
CAP9 == [i \in IDS |-> 100]

\* Requests: away to away, same-chain, away to home; Carol's move toward Bob competes for his cap.
REQ == [r \in {"xx", "same", "home", "cxx", "csame", "bh", "bc", "nat", "bxx"} |->
          CASE r = "xx"    -> [kind |-> "MOVE", from |-> "aA", to |-> "bB", min |-> 0, rmax |-> 2]
            [] r = "same"  -> [kind |-> "MOVE", from |-> "aA", to |-> "bA", min |-> 0, rmax |-> 2]
            [] r = "home"  -> [kind |-> "MOVE", from |-> "aA", to |-> "bH", min |-> 0, rmax |-> 2]
            [] r = "cxx"   -> [kind |-> "MOVE", from |-> "cA", to |-> "bB", min |-> 0, rmax |-> 2]
            [] r = "csame" -> [kind |-> "MOVE", from |-> "cA", to |-> "bA", min |-> 0, rmax |-> 2]
            [] r = "bh"    -> [kind |-> "BH",   from |-> "bA", to |-> "bH", min |-> 0, rmax |-> 2]
            \* Bob forwards on A what Alice sent him (sc89; run names "hc5")
            [] r = "bc"    -> [kind |-> "MOVE", from |-> "bA", to |-> "cA", min |-> 0, rmax |-> 2]
            \* a native from: Bob's home wallet to Alice@A (r16)
            [] r = "nat"   -> [kind |-> "MOVE", from |-> "bH", to |-> "aA", min |-> 0, rmax |-> 2]
            \* an internal cross-chain move: Bob@A to Bob@B (sc8)
            [] r = "bxx"   -> [kind |-> "MOVE", from |-> "bA", to |-> "bB", min |-> 0, rmax |-> 2]]

R_XX == {"xx"}
R_SAME == {"same"}
R_HOME == {"home"}
R_XX_CSAME == {"xx", "csame"}
R_SAME_CXX == {"same", "cxx"}
R_SAME_CSAME == {"same", "csame"}
R_BH == {"bh"}
R_SAME_BH == {"same", "bh"}
R_SAME_BC == {"same", "bc"}
R_NAT == {"nat"}
R_SAME_NAT == {"same", "nat"}
R_SAME_BXX == {"same", "bxx"}
R_XX_SAME_CSAME == {"xx", "same", "csame"}
R_SAME_CSAME_BC == {"same", "csame", "bc"}

NOHOSTILE == {}
HOSTILE_A == {"A"}
HOSTILE_B == {"B"}
CLOSE_B == {"B"}
CLOSE_A == {"A"}
CLOSE_NONE == {}
SKEW_BLAG3 == [c \in CHAINS |-> IF c = "B" THEN -3 ELSE 0]
SKEW0 == [c \in CHAINS |-> 0]
SKEW_LAG1 == [c \in CHAINS |-> IF c = "A" THEN -1 ELSE 0]
SKEW_LAG3 == [c \in CHAINS |-> IF c = "A" THEN -3 ELSE 0]
SKEW_LAG5 == [c \in CHAINS |-> IF c = "A" THEN -5 ELSE 0]
SKEW_LEAD1 == [c \in CHAINS |-> IF c = "A" THEN 1 ELSE 0]
SKEW_LEAD2 == [c \in CHAINS |-> IF c = "A" THEN 2 ELSE 0]
SKEW_ALAG1_BLEAD1 == [c \in CHAINS |-> IF c = "A" THEN -1 ELSE 1]
SKEW_ALEAD1_BLAG1 == [c \in CHAINS |-> IF c = "A" THEN 1 ELSE -1]
\* Reachability probes. runs.py lists a run's probes in its _probes; the others are for runs by hand.
P_XXDone == ~(home.tk["xx"] # NONE /\ home.tk["xx"].st = "Done" /\ lite["B"].bal["bB"] = 2)
P_SameDone == ~(home.tk["same"] # NONE /\ home.tk["same"].st = "Done" /\ lite["A"].bal["bA"] > 0)
P_Cancelled(r) == ~(home.tk[r] # NONE /\ home.tk[r].st = "Cancelled")
P_HeldNoDest(r) == ~(home.tk[r] # NONE /\ home.tk[r].st = "OnHold" /\ home.tk[r].dest = "none")
P_XXCancelled == P_Cancelled("xx")
P_SameHeld == P_HeldNoDest("same")
P_XXHeld == P_HeldNoDest("xx")
P_ClosedByHand == ~(\E r \in ReqIds : home.tk[r] # NONE /\ home.tk[r].cbh > 0)
P_IdMint == ~(\E i \in {"aI", "cI", "bI"} : home.native[i] > 0)
P_BHDone == ~(home.tk["bh"] # NONE /\ home.tk["bh"].st = "Done" /\ home.native["bH"] = 2)
P_ApprNarrowedDone == ~(home.tk["same"] # NONE /\ home.tk["same"].st = "Done" /\ home.tk["same"].amax = 1
                        /\ lite["A"].bal["bA"] = 1)
P_ApprRefused == ~(home.tk["same"] # NONE /\ home.tk["same"].st = "Cancelled" /\ lite["A"].fin["same"] = NONE)
\* D12 fires: a receipt on the former route is applied for a ticket pinned to the new one.
P_D12 == ~(lite["A"].rv = 0 /\ home.rv["A"] = 1 /\ home.tk["same"] # NONE /\ home.tk["same"].pin0 = 1
           /\ home.tk["same"].st = "Done")
\* D10's containment holds an Open ticket.
P_Cont == ~(Contained(home, "A") /\ home.tk["same"] # NONE /\ home.tk["same"].st = "Open")
\* D9 fires: a receipt with no record carried uncounted credit along.
P_Carry == ~(\E r \in ReqIds : home.tk[r] # NONE /\ home.tk[r].cd > 0)
\* sc89 settles: both moves reversed and the book matches the chain.
P_HC5Reversed == ~(home.tk["same"] # NONE /\ home.tk["same"].st = "Done" /\ home.tk["same"].dest = "cancel"
                   /\ home.tk["bc"] # NONE /\ home.tk["bc"].st = "Done" /\ lite["A"].bal["aA"] = 2)
P_NatDone == ~(home.tk["nat"] # NONE /\ home.tk["nat"].st = "Done" /\ lite["A"].bal["aA"] > 2)
P_Gated == ~(\E m \in net : m.ty = "T" /\ m.route = "rc")
P_Orphan == ~(\E c \in CHAINS : Orphan(c) > 0)
P_Reopened == ~(lev.reopen > 0 /\ home.closed = {})
P_FormerAdmitted == ~(\E r \in ReqIds : home.tk[r] # NONE /\ home.tk[r].held # NONE /\ home.former["A"] # NONE)
P_Shallow == ~(nshal > 0)
\* sc30: the Lite keeps a dropped copy whose valid until is later than the canonical ticket's.
P_EarlierSlot == ~(\E r \in ReqIds : home.tk[r] # NONE /\ home.tk[r].pair # NONE /\ "A" \in DOMAIN lite
                     /\ lite["A"].copy[r] # NONE /\ lite["A"].copy[r].vu > home.tk[r].vu)
=============================================================================
