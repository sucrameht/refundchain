// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// TEST TOKEN ONLY: not actual SGD, not backed by a bank or reserves.
contract MockSGD is ERC20 {
    constructor() ERC20("Demo Singapore Dollar", "dSGD") {
        _mint(msg.sender, 1_000_000);
    }

    // Whole demo dollars, so enter 1200 rather than 1200 * 10**18.
    function decimals() public pure override returns (uint8) {
        return 0;
    }
}

contract RefundChain is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MONTH = 30 days;
    uint256 public constant PLAN_MONTHS = 12;

    IERC20 public immutable sgd;
    address public immutable registrar;
    address[3] public closureApprovers;
    bool public immutable demoMode;
    uint256 public demoTime;
    uint256 public nextMembershipId;

    mapping(address => bool) public approvedMerchants;
    mapping(address => uint256) public merchantClosedAt;
    mapping(address => mapping(address => bool)) public hasVotedToClose;
    mapping(address => uint8) public closureVotes;

    struct Membership {
        address customer;
        address merchant;
        uint256 total;
        uint256 startTime;
        uint256 paidToMerchant;
        uint256 refundedToCustomer;
    }

    mapping(uint256 => Membership) public memberships;

    event MerchantApproved(address indexed merchant);
    event ClosureVote(address indexed merchant, address indexed approver, uint8 votes);
    event MerchantClosed(address indexed merchant, uint256 closureTime);
    event MembershipCreated(uint256 indexed id, address indexed customer, address indexed merchant, uint256 amount);
    event MerchantPaid(uint256 indexed id, uint256 amount);
    event CustomerRefunded(uint256 indexed id, uint256 amount);
    event DemoTimeAdvanced(uint256 newTime);

    constructor(address token, bool isDemo, address approver2, address approver3) {
        require(token != address(0), "Invalid token");
        require(approver2 != address(0) && approver3 != address(0), "Invalid approver");
        require(approver2 != msg.sender && approver3 != msg.sender && approver2 != approver3, "Approvers must differ");
        sgd = IERC20(token);
        registrar = msg.sender;
        closureApprovers = [msg.sender, approver2, approver3];
        demoMode = isDemo;
        demoTime = block.timestamp;
    }

    modifier onlyRegistrar() {
        require(msg.sender == registrar, "Only registrar");
        _;
    }

    modifier onlyClosureApprover() {
        require(
            msg.sender == closureApprovers[0] ||
            msg.sender == closureApprovers[1] ||
            msg.sender == closureApprovers[2],
            "Not a closure approver"
        );
        _;
    }

    function currentTime() public view returns (uint256) {
        return demoMode ? demoTime : block.timestamp;
    }

    // Classroom simulation only. Disable demoMode for real-time operation.
    function advanceDemoMonths(uint256 monthsToAdvance) external onlyRegistrar {
        require(demoMode, "Not demo mode");
        require(monthsToAdvance > 0, "Must advance time");
        demoTime += monthsToAdvance * MONTH;
        emit DemoTimeAdvanced(demoTime);
    }

    function approveMerchant(address merchant) external onlyRegistrar {
        require(merchant != address(0), "Invalid merchant");
        require(!approvedMerchants[merchant], "Already registered");
        require(merchantClosedAt[merchant] == 0, "Merchant closed");
        approvedMerchants[merchant] = true;
        emit MerchantApproved(merchant);
    }

    // Two different consortium approvers must confirm a closure.
    function voteToCloseMerchant(address merchant) external onlyClosureApprover {
        require(approvedMerchants[merchant], "Unknown merchant");
        require(merchantClosedAt[merchant] == 0, "Already closed");
        require(!hasVotedToClose[merchant][msg.sender], "Already voted");

        hasVotedToClose[merchant][msg.sender] = true;
        closureVotes[merchant] += 1;
        emit ClosureVote(merchant, msg.sender, closureVotes[merchant]);

        if (closureVotes[merchant] >= 2) {
            merchantClosedAt[merchant] = currentTime();
            emit MerchantClosed(merchant, currentTime());
        }
    }

    // Customer must first approve this contract to spend the token amount.
    function createMembership(address merchant, uint256 amount) external nonReentrant returns (uint256 id) {
        require(approvedMerchants[merchant], "Merchant not approved");
        require(merchantClosedAt[merchant] == 0, "Merchant is closed");
        require(amount > 0, "Amount must be positive");

        // Require an ordinary non-fee-on-transfer payment token.
        uint256 beforeBalance = sgd.balanceOf(address(this));
        sgd.safeTransferFrom(msg.sender, address(this), amount);
        require(sgd.balanceOf(address(this)) == beforeBalance + amount, "Unsupported token fee");

        id = ++nextMembershipId;
        memberships[id] = Membership({
            customer: msg.sender,
            merchant: merchant,
            total: amount,
            startTime: currentTime(),
            paidToMerchant: 0,
            refundedToCustomer: 0
        });
        emit MembershipCreated(id, msg.sender, merchant, amount);
    }

    function totalEarned(uint256 id) public view returns (uint256) {
        Membership storage m = memberships[id];
        require(m.customer != address(0), "Membership not found");

        uint256 effectiveTime = currentTime();
        uint256 closureTime = merchantClosedAt[m.merchant];
        if (closureTime != 0 && closureTime < effectiveTime) {
            effectiveTime = closureTime;
        }
        if (effectiveTime <= m.startTime) return 0;

        uint256 completedMonths = (effectiveTime - m.startTime) / MONTH;
        if (completedMonths > PLAN_MONTHS) completedMonths = PLAN_MONTHS;
        return (m.total * completedMonths) / PLAN_MONTHS;
    }

    function availableForMerchant(uint256 id) public view returns (uint256) {
        return totalEarned(id) - memberships[id].paidToMerchant;
    }

    function refundable(uint256 id) public view returns (uint256) {
        Membership storage m = memberships[id];
        require(m.customer != address(0), "Membership not found");
        if (merchantClosedAt[m.merchant] == 0) return 0;
        return m.total - totalEarned(id) - m.refundedToCustomer;
    }

    function escrowBalance(uint256 id) external view returns (uint256) {
        Membership storage m = memberships[id];
        require(m.customer != address(0), "Membership not found");
        return m.total - m.paidToMerchant - m.refundedToCustomer;
    }

    // A merchant can withdraw earned installments, even after closure.
    function withdrawEarned(uint256 id) external nonReentrant {
        Membership storage m = memberships[id];
        require(msg.sender == m.merchant, "Only merchant");
        uint256 amount = availableForMerchant(id);
        require(amount > 0, "Nothing earned yet");
        m.paidToMerchant += amount;
        sgd.safeTransfer(m.merchant, amount);
        emit MerchantPaid(id, amount);
    }

    // Customer can reclaim only the unearned amount after verified closure.
    function refundUnused(uint256 id) external nonReentrant {
        Membership storage m = memberships[id];
        require(msg.sender == m.customer, "Only customer");
        uint256 amount = refundable(id);
        require(amount > 0, "No refundable balance");
        m.refundedToCustomer += amount;
        sgd.safeTransfer(m.customer, amount);
        emit CustomerRefunded(id, amount);
    }
}
