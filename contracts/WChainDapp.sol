// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

// Importing the MyToken contract and IERC20 interface from OpenZeppelin
import "./Token.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Main contract inheriting from the MyToken contract
contract WChainDapp is MyToken {
    address public owner; // Owner of the contract
    IERC20 public dappToken; // The token used in the contract

    // Struct to define the properties of each reward tier
    struct Tier {
        uint256 rewardRate; // The reward rate for the tier (in basis points)
        uint256 lockTime; // Lock time for the tier (in seconds)
    }

    // Struct to hold information about a user's deposit
    struct Deposit {
        uint256 amount; // The amount the user has deposited
        uint256 reward; // The reward accumulated for this deposit
        uint256 unlockTime; // The time when the deposit can be withdrawn
        bool claimed; // Whether the deposit has been claimed or not
    }

    // Mappings to store contract state:
    mapping(uint8 => Tier) public tiers; // Mapping of tier id to its respective properties
    mapping(address => mapping(uint8 => Deposit)) public deposits; // Mapping of user address to tier deposits
    mapping(address => bool) public whitelisted; // Mapping of whitelisted users
    mapping(address => uint256) public lastDepositTime; // The last time a user made a deposit
    mapping(address => bool) public hasClaimed; // Whether a user has claimed their deposit

    uint256 public depositCooldown = 1 days; // The cooldown period between deposits for a user

    // Events to log important contract actions
    event TierUpdated(uint8 indexed tier, uint256 rewardRate, uint256 lockTime);
    event Deposited(
        address indexed user,
        uint256 amount,
        uint8 tier,
        uint256 reward,
        uint256 unlockTime
    );
    event Claimed(address indexed user, uint256 amount);
    event Whitelisted(address indexed user, bool status);

    // Custom errors to handle require statement failures
    error NotOwner();
    error NotWhitelisted();
    error NoActiveDeposit(uint8 tier);
    error DepositCooldownNotReached();
    error AlreadyClaimed();
    error InvalidTier(uint8 tier);
    error DepositAmountZero();
    error DepositLocked(uint256 unlockTime);

    // Modifier to allow only the contract owner to execute a function
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // Modifier to allow only whitelisted users to execute a function
    modifier onlyWhitelisted() {
        if (!whitelisted[msg.sender]) revert NotWhitelisted();
        _;
    }

    // Modifier to ensure the user has an active deposit for the specified tier
    modifier hasDeposit(uint8 _tier) {
        if (deposits[msg.sender][_tier].amount == 0)
            revert NoActiveDeposit(_tier);
        _;
    }

    // Modifier to ensure the deposit cooldown period has passed before allowing another deposit
    modifier canDeposit() {
        if (block.timestamp < lastDepositTime[msg.sender] + depositCooldown)
            revert DepositCooldownNotReached();
        _;
    }

    // Modifier to ensure that the user has not already claimed their deposit for the tier
    modifier canClaim(uint8 _tier) {
        if (hasClaimed[msg.sender]) revert AlreadyClaimed();
        _;
    }

    // Constructor to initialize the contract with the token address
    constructor(address _token) {
        owner = msg.sender; // Set the owner of the contract to the deployer
        dappToken = IERC20(_token); // Initialize the token contract
        // Initialize default tiers with reward rates and lock times
        tiers[1] = Tier(500, 7 days); // Tier 1: 5% reward, 7-day lock
        tiers[2] = Tier(1000, 14 days); // Tier 2: 10% reward, 14-day lock
        tiers[3] = Tier(1500, 30 days); // Tier 3: 15% reward, 30-day lock
    }

    // Function to update the reward rate and lock time for a specific tier
    function updateTier(
        uint8 _tier,
        uint256 _rewardRate,
        uint256 _lockTime
    ) external onlyOwner {
        if (_tier == 0) revert InvalidTier(_tier); // Reject tier 0 as invalid
        tiers[_tier] = Tier(_rewardRate, _lockTime); // Update tier properties
        emit TierUpdated(_tier, _rewardRate, _lockTime); // Emit an event for the update
    }

    // Function to whitelist or remove a user from the whitelist
    function setWhitelist(address _user, bool _status) external onlyOwner {
        whitelisted[_user] = _status; // Update the whitelist status for the user
        emit Whitelisted(_user, _status); // Emit an event for the change
    }

    // Function to deposit tokens into the contract and start earning rewards
    function deposit(
        uint8 _tier,
        uint256 _amount
    ) external payable onlyWhitelisted canDeposit {
        if (_amount == 0) revert DepositAmountZero(); // Reject zero deposit amounts
        if (tiers[_tier].lockTime == 0) revert InvalidTier(_tier); // Reject invalid tiers

        Deposit storage userDeposit = deposits[msg.sender][_tier]; // Get the user's deposit details for the specified tier
        // Calculate the reward based on the tier's reward rate
        uint256 reward = (_amount * tiers[_tier].rewardRate) / 10000;
        dappToken.transferFrom(msg.sender, address(this), _amount); // Transfer tokens from the user to the contract

        // Update the user's deposit information
        deposits[msg.sender][_tier] = Deposit({
            amount: userDeposit.amount + _amount,
            reward: userDeposit.reward + reward,
            unlockTime: userDeposit.unlockTime +
                block.timestamp +
                tiers[_tier].lockTime,
            claimed: false
        });

        lastDepositTime[msg.sender] = block.timestamp; // Update the last deposit time

        emit Deposited(
            msg.sender,
            _amount,
            _tier,
            reward,
            block.timestamp + tiers[_tier].lockTime
        ); // Emit a deposit event
    }

    // Function to claim the deposited amount and its reward after the lock period
    function claim(
        uint8 _tier
    ) external onlyWhitelisted hasDeposit(_tier) canClaim(_tier) {
        Deposit storage userDeposit = deposits[msg.sender][_tier]; // Get the user's deposit for the tier
        if (block.timestamp <= userDeposit.unlockTime)
            revert DepositLocked(userDeposit.unlockTime); // Reject if the deposit is still locked

        uint256 totalAmount = userDeposit.amount + userDeposit.reward; // Calculate the total amount to be claimed
        hasClaimed[msg.sender] = true; // Mark the user as having claimed their deposit

        // Reset the user's deposit information
        deposits[msg.sender][_tier] = Deposit({
            amount: 0,
            reward: 0,
            unlockTime: 0,
            claimed: true
        });

        dappToken.transfer(msg.sender, totalAmount); // Transfer the total amount (principal + reward) to the user
        emit Claimed(msg.sender, totalAmount); // Emit a claim event
    }

    // Function to get the details of a user's deposit for a specific tier
    function getDepositDetails(
        address _user,
        uint8 _tier
    ) external view returns (uint256, uint256, uint256, bool) {
        Deposit memory userDeposit = deposits[_user][_tier]; // Get the deposit details
        return (
            userDeposit.amount,
            userDeposit.reward,
            userDeposit.unlockTime,
            userDeposit.claimed
        ); // Return the details
    }

    // Fallback function to accept Ether sent to the contract
    receive() external payable {}
}
