// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title PrivacyBountyJudge
 * @notice Commit-reveal bounty system with Ritual AI batch judging.
 *         Answers stay hidden during the submission phase and are
 *         revealed only after judging is complete.
 *
 * Lifecycle:
 *   1. Owner creates bounty  (submissionDeadline, revealDeadline set)
 *   2. Participants submit commitment hash  (before submissionDeadline)
 *   3. Participants reveal answer + salt   (submissionDeadline < t < revealDeadline)
 *   4. Owner calls judgeAll()             (after revealDeadline)
 *   5. Ritual AI callback sets judging result
 *   6. Owner calls finalizeWinner()       (after judging is complete)
 */
contract PrivacyBountyJudge {
    // ─── Structs ───────────────────────────────────────────────────────────────

    struct Submission {
        bytes32 commitment;   // keccak256(answer, salt, sender, bountyId)
        string  answer;       // filled in during reveal phase
        bool    committed;
        bool    revealed;
    }

    struct Bounty {
        address owner;
        string  description;
        uint256 reward;               // ETH in wei
        uint256 submissionDeadline;   // timestamp: commit phase ends
        uint256 revealDeadline;       // timestamp: reveal phase ends
        bool    judged;
        bool    finalized;
        uint256 winnerIndex;          // index into participants array
        address[] participants;       // ordered list of submitters
        string  judgingResult;        // raw LLM output stored for transparency
    }

    // ─── State ─────────────────────────────────────────────────────────────────

    uint256 public bountyCount;

    // bountyId => Bounty
    mapping(uint256 => Bounty) private bounties;

    // bountyId => participant address => Submission
    mapping(uint256 => mapping(address => Submission)) private submissions;

    // ─── Events ────────────────────────────────────────────────────────────────

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        uint256 reward,
        uint256 submissionDeadline,
        uint256 revealDeadline
    );

    event CommitmentSubmitted(uint256 indexed bountyId, address indexed participant);

    event AnswerRevealed(uint256 indexed bountyId, address indexed participant);

    event JudgingRequested(uint256 indexed bountyId);

    event JudgingCompleted(uint256 indexed bountyId, string result);

    event WinnerFinalized(uint256 indexed bountyId, address indexed winner, uint256 reward);

    // ─── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyBountyOwner(uint256 bountyId) {
        require(msg.sender == bounties[bountyId].owner, "Not bounty owner");
        _;
    }

    modifier bountyExists(uint256 bountyId) {
        require(bountyId < bountyCount, "Bounty does not exist");
        _;
    }

    // ─── Core Functions ────────────────────────────────────────────────────────

    /**
     * @notice Create a new bounty. The reward is sent as msg.value.
     * @param description    Human-readable bounty prompt / problem statement.
     * @param submissionDeadline  Unix timestamp after which no new commits accepted.
     * @param revealDeadline      Unix timestamp after which reveal phase closes.
     */
    function createBounty(
        string calldata description,
        uint256 submissionDeadline,
        uint256 revealDeadline
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "Reward must be > 0");
        require(submissionDeadline > block.timestamp, "Submission deadline must be in the future");
        require(revealDeadline > submissionDeadline, "Reveal deadline must be after submission deadline");

        bountyId = bountyCount++;

        Bounty storage b = bounties[bountyId];
        b.owner               = msg.sender;
        b.description         = description;
        b.reward              = msg.value;
        b.submissionDeadline  = submissionDeadline;
        b.revealDeadline      = revealDeadline;

        emit BountyCreated(bountyId, msg.sender, msg.value, submissionDeadline, revealDeadline);
    }

    /**
     * @notice Submit a commitment hash during the submission phase.
     * @dev    commitment = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
     *         Including msg.sender and bountyId prevents commitment front-running.
     */
    function submitCommitment(uint256 bountyId, bytes32 commitment)
        external
        bountyExists(bountyId)
    {
        Bounty storage b = bounties[bountyId];
        require(block.timestamp <= b.submissionDeadline, "Submission phase has ended");
        require(!submissions[bountyId][msg.sender].committed, "Already committed");
        require(commitment != bytes32(0), "Commitment cannot be empty");

        submissions[bountyId][msg.sender] = Submission({
            commitment: commitment,
            answer:     "",
            committed:  true,
            revealed:   false
        });
        b.participants.push(msg.sender);

        emit CommitmentSubmitted(bountyId, msg.sender);
    }

    /**
     * @notice Reveal the answer and salt after the submission deadline.
     *         The contract verifies the commitment hash before storing the answer.
     */
    function revealAnswer(
        uint256 bountyId,
        string calldata answer,
        bytes32 salt
    ) external bountyExists(bountyId) {
        Bounty storage b = bounties[bountyId];
        require(block.timestamp > b.submissionDeadline, "Submission phase not over yet");
        require(block.timestamp <= b.revealDeadline,    "Reveal phase has ended");

        Submission storage s = submissions[bountyId][msg.sender];
        require(s.committed,  "No commitment found");
        require(!s.revealed,  "Already revealed");

        // Verify the commitment
        bytes32 expected = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId));
        require(expected == s.commitment, "Commitment mismatch: invalid answer or salt");

        s.answer   = answer;
        s.revealed = true;

        emit AnswerRevealed(bountyId, msg.sender);
    }

    /**
     * @notice Trigger batch AI judging via Ritual after the reveal deadline.
     * @dev    llmInput is the encoded payload sent to the Ritual LLM precompile.
     *         The contract collects all revealed answers and bundles them into
     *         a single judging request — NOT one call per submission.
     *
     *         On a live Ritual deployment this function would call the LLM
     *         precompile (0x0800) and the result would arrive asynchronously
     *         via receiveJudgingResult(). For EVM-only deployments the owner
     *         provides llmInput and the result is supplied off-chain then
     *         recorded through the callback pattern below.
     */
    function judgeAll(uint256 bountyId, bytes calldata llmInput)
        external
        bountyExists(bountyId)
        onlyBountyOwner(bountyId)
    {
        Bounty storage b = bounties[bountyId];
        require(block.timestamp > b.revealDeadline, "Reveal phase not over yet");
        require(!b.judged, "Already judged");

        // Collect only the revealed answers
        uint256 revealedCount = 0;
        for (uint256 i = 0; i < b.participants.length; i++) {
            if (submissions[bountyId][b.participants[i]].revealed) {
                revealedCount++;
            }
        }
        require(revealedCount > 0, "No revealed answers to judge");

        // Suppress unused variable warning — in a full Ritual integration
        // llmInput would be forwarded to the LLM precompile here.
        // The `llmInput` payload should contain all revealed answers bundled
        // by the off-chain helper or the frontend before calling judgeAll().
        (llmInput);

        // Emit event so Ritual node / off-chain relayer picks up the request
        emit JudgingRequested(bountyId);

        // NOTE: In a real Ritual deployment the LLM precompile is called here
        // and receiveJudgingResult() is invoked asynchronously by the node.
    }

    /**
     * @notice Callback from Ritual node (or owner acting as trusted relay)
     *         to record the AI judging result.
     * @dev    In production this would be restricted to the Ritual executor
     *         address. For the workshop / EVM-only track the owner supplies it.
     */
    function receiveJudgingResult(uint256 bountyId, string calldata result)
        external
        bountyExists(bountyId)
        onlyBountyOwner(bountyId)  // replace with Ritual executor ACL in production
    {
        Bounty storage b = bounties[bountyId];
        require(!b.judged, "Already judged");

        b.judgingResult = result;
        b.judged        = true;

        emit JudgingCompleted(bountyId, result);
    }

    /**
     * @notice Owner picks the winner (human-in-the-loop step).
     *         AI recommends, human finalizes — the contract enforces the payout.
     * @param winnerIndex  Index in the participants array.
     */
    function finalizeWinner(uint256 bountyId, uint256 winnerIndex)
        external
        bountyExists(bountyId)
        onlyBountyOwner(bountyId)
    {
        Bounty storage b = bounties[bountyId];
        require(b.judged,     "Judging not complete");
        require(!b.finalized, "Already finalized");
        require(winnerIndex < b.participants.length, "Invalid winner index");

        address winner = b.participants[winnerIndex];
        require(submissions[bountyId][winner].revealed, "Winner must have revealed their answer");

        b.finalized    = true;
        b.winnerIndex  = winnerIndex;

        emit WinnerFinalized(bountyId, winner, b.reward);

        // Transfer reward — checks-effects-interactions pattern already satisfied
        (bool ok, ) = winner.call{value: b.reward}("");
        require(ok, "Reward transfer failed");
    }

    // ─── View Helpers ──────────────────────────────────────────────────────────

    /// Returns basic bounty metadata (no answers — those stay hidden until revealed).
    function getBounty(uint256 bountyId)
        external
        view
        bountyExists(bountyId)
        returns (
            address owner,
            string memory description,
            uint256 reward,
            uint256 submissionDeadline,
            uint256 revealDeadline,
            bool judged,
            bool finalized,
            uint256 participantCount
        )
    {
        Bounty storage b = bounties[bountyId];
        return (
            b.owner,
            b.description,
            b.reward,
            b.submissionDeadline,
            b.revealDeadline,
            b.judged,
            b.finalized,
            b.participants.length
        );
    }

    /// Returns all revealed answers for a bounty (only readable after reveal phase).
    /// Before the reveal deadline answers are empty strings even if committed.
    function getRevealedAnswers(uint256 bountyId)
        external
        view
        bountyExists(bountyId)
        returns (address[] memory participants, string[] memory answers)
    {
        Bounty storage b = bounties[bountyId];
        participants = b.participants;
        answers = new string[](b.participants.length);
        for (uint256 i = 0; i < b.participants.length; i++) {
            Submission storage s = submissions[bountyId][b.participants[i]];
            // Only expose the answer if it has been publicly revealed
            if (s.revealed) {
                answers[i] = s.answer;
            }
        }
    }

    /// Returns the AI judging result string (empty until judging is complete).
    function getJudgingResult(uint256 bountyId)
        external
        view
        bountyExists(bountyId)
        returns (string memory)
    {
        return bounties[bountyId].judgingResult;
    }

    /// Returns a participant's commitment status (does NOT leak the answer).
    function getSubmissionStatus(uint256 bountyId, address participant)
        external
        view
        bountyExists(bountyId)
        returns (bool committed, bool revealed)
    {
        Submission storage s = submissions[bountyId][participant];
        return (s.committed, s.revealed);
    }

    // ─── Helper: commitment hash preview ───────────────────────────────────────

    /**
     * @notice Pure helper so participants can verify their commitment off-chain
     *         before calling submitCommitment().
     */
    function computeCommitment(
        string calldata answer,
        bytes32 salt,
        address sender,
        uint256 bountyId
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(answer, salt, sender, bountyId));
    }
}
