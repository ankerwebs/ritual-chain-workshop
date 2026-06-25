# Architecture Note: Commit-Reveal vs Ritual-Native Encrypted Submissions

## Overview

Both approaches solve the same problem — preventing answer copying before judging — but they make different trade-offs between trust assumptions, complexity, and when answers are exposed.

---

## Approach 1: Commit-Reveal (Required Track)

### How it works

```
Participant  ──[hash only]──▶  Chain  (submission phase)
Participant  ──[answer+salt]──▶  Chain  (reveal phase, after sub deadline)
Owner        ──[judgeAll]──▶  Ritual  (batch LLM request, after reveal deadline)
Ritual       ──[result]──▶  Chain  (callback)
Owner        ──[finalizeWinner]──▶  Chain  (payout)
```

### What lives where

| Data | Location | Visibility |
|---|---|---|
| Commitment hash | On-chain | Public (reveals nothing) |
| Plaintext answer | Off-chain (participant's device) | Hidden until reveal |
| Revealed answer | On-chain | Public after reveal phase |
| LLM judging result | On-chain | Public after judging |
| Salt | Off-chain only | Never published |

### Trade-offs

**✅ Pros**
- Works on any EVM chain — no Ritual dependency required for the commit phase
- Simple, auditable logic — the commitment formula is a single keccak256 call
- No trusted third party needed for the hiding step

**❌ Cons**
- Answers become public **before** AI judging happens (during the reveal phase)
- A competitor who monitors the chain can read all revealed answers the moment they appear, even if the judging hasn't started yet
- The window between reveal deadline and judgeAll() is an information leak

---

## Approach 2: Ritual-Native Encrypted Submissions (Advanced Track)

### How it works

```
Participant  ──[encrypt(answer, TEE_pubkey)]──▶  Chain / IPFS
Owner        ──[judgeAll]──▶  Ritual TEE  (decrypts answers inside enclave)
                                             ──▶  LLM  (sees plaintext, inside TEE)
                                             ──▶  Chain  (result + revealed bundle hash)
Owner        ──[finalizeWinner]──▶  Chain  (payout)
```

### What lives where

| Data | Location | Visibility |
|---|---|---|
| Encrypted answer ciphertext | On-chain or IPFS | Public but unreadable |
| Plaintext answer | Inside Ritual TEE only | Never public until judging complete |
| TEE public key | On-chain (TEEServiceRegistry) | Public |
| LLM judging result | On-chain | Public after judging |
| Revealed answer bundle | IPFS (post-judging) | Public after judging |
| Bundle hash | On-chain | Public after judging |

### Detailed Flow

1. **Key discovery**: Participant reads the Ritual executor's public key from `TEEServiceRegistry`.

2. **Encryption**: Participant encrypts their answer using ECIES with the TEE public key:
   ```
   ciphertext = ECIES_encrypt(TEE_pubkey, answer)
   ```

3. **Submission**: Participant calls `submitEncrypted(bountyId, ciphertext)` — or stores ciphertext on IPFS and submits only the content hash on-chain to save gas.

4. **Judging**: Owner calls `judgeAll()`. The Ritual node:
   - Runs inside a hardware TEE (e.g., Intel TDX)
   - Decrypts all ciphertexts using the TEE's private key (never exposed outside the enclave)
   - Sends all plaintext answers together to the LLM in one batch request
   - Receives the ranked result
   - Publishes the full revealed answers bundle to IPFS
   - Stores `revealedAnswersHash = keccak256(bundle)` and `revealedAnswersRef = "ipfs://..."` on-chain

5. **Verification**: Anyone can fetch the IPFS bundle and verify:
   ```
   keccak256(bundle) == revealedAnswersHash  (stored on-chain)
   ```

6. **Finalization**: Owner confirms winner and the contract pays out.

### Sample final output shape

```json
{
  "winnerIndex": 2,
  "ranking": [
    { "index": 2, "score": 94, "reason": "Best satisfies the rubric." },
    { "index": 0, "score": 78, "reason": "Correct but too verbose." },
    { "index": 1, "score": 61, "reason": "Missed the key constraint." }
  ],
  "revealedAnswersRef": "ipfs://bafybeig...",
  "revealedAnswersHash": "0xabc123...",
  "summary": "Submission 2 is the strongest answer."
}
```

### Trade-offs

**✅ Pros**
- Answers are **never** exposed before judging is complete — not even during a "reveal phase"
- Stronger privacy guarantee: only the Ritual TEE can see plaintext answers
- Attestation from the TEE means the result is cryptographically verifiable
- Large answers can live off-chain (IPFS), keeping gas costs low

**❌ Cons**
- Requires Ritual Chain deployment — not portable to arbitrary EVM chains
- Additional trust assumption: the TEE hardware and Ritual executor must be non-compromised
- More complex key management; if the TEE key rotates or the executor goes offline, judging may stall
- IPFS availability is not guaranteed; the revealed bundle could become inaccessible

---

## Side-by-Side Comparison

| Property | Commit-Reveal | Ritual TEE |
|---|---|---|
| When answers are exposed | During reveal phase (before judging) | Only after judging completes |
| Chain dependency | Any EVM | Ritual Chain |
| Privacy assumption | Cryptographic hash pre-image hiding | TEE hardware + Ritual executor |
| Gas efficiency | Moderate (answers stored on-chain) | Low (ciphertexts or IPFS hashes) |
| Complexity | Low | High |
| Auditability | High (all data on-chain) | Medium (bundle on IPFS, hash on-chain) |
| Answer confidentiality window | Until reveal deadline | Until judging callback |

---

## Architecture Diagram: Ritual-Native Flow

```
┌─────────────┐        encrypt(answer, TEE_pk)        ┌──────────────┐
│ Participant  │ ────────────────────────────────────▶ │  Chain/IPFS  │
└─────────────┘                                        └──────┬───────┘
                                                              │ ciphertext ref
                                                              ▼
┌─────────────┐       judgeAll(bountyId, ...)         ┌──────────────┐
│    Owner    │ ────────────────────────────────────▶ │    Chain     │
└─────────────┘                                        └──────┬───────┘
                                                              │ event: JudgingRequested
                                                              ▼
                                               ┌──────────────────────────┐
                                               │     Ritual TEE Node      │
                                               │  ┌────────────────────┐  │
                                               │  │  decrypt answers   │  │
                                               │  │  (private key in   │  │
                                               │  │   enclave only)    │  │
                                               │  └────────┬───────────┘  │
                                               │           │               │
                                               │  ┌────────▼───────────┐  │
                                               │  │   LLM batch judge  │  │
                                               │  └────────┬───────────┘  │
                                               └───────────┼──────────────┘
                                                           │ result + attestation
                               ┌───────────────────────────▼───────────────┐
                               │  publish bundle → IPFS                     │
                               │  store hash + ref → Chain                  │
                               │  call receiveJudgingResult() on contract   │
                               └───────────────────────────────────────────┘
```

---

## Recommendation

For a **workshop / EVM-only** deployment: use commit-reveal. It is simple, correct, and trustless for the hiding step.

For a **production Ritual deployment**: use the TEE approach. The stronger privacy guarantee (answers never public until judging is done) is worth the added complexity when real money is at stake.

A hybrid is also viable: use commit-reveal on any chain but route the `judgeAll()` call through Ritual's LLM precompile. That gets you Ritual's batch inference and on-chain attestation without needing full TEE submission encryption.
