// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    VRFConsumerBaseV2Plus,
    IVRFCoordinatorV2Plus
} from "chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {AutomationCompatibleInterface} from
    "chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";

/**
 * @title LotterySystem
 * @dev Contract for managing lotteries using USDC tokens
 */
contract LotterySystem is ReentrancyGuard, VRFConsumerBaseV2Plus, AutomationCompatibleInterface {
    // USDC token contract
    IERC20 public USDC;
    IPool public aavePool;

    // Fixed VRF coordinator address
    // address public vrfCoordinator = 0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B;
    // 0x271682DEB8C4E0901D1a1550aD2e64D568E69909; for Sepolia

    // Custom ownership implementation
    address private _lotteryOwner;

    // Lottery structure
    struct Lottery {
        uint256 id;
        uint256 deadline;
        uint256 stakingDeadline;
        bool finalized;
        bool stakingFinalized;
        address winner;
        uint256 randomRequestId;
        uint256 randomNumber;
        uint256 yield;
        address initiator;
    }

    // Mapping from lottery ID to Lottery
    mapping(uint256 => Lottery) public lotteries;

    // Mapping from request ID to random lottery ID
    mapping(uint256 => uint256) public randomLotteryIds;

    // Mapping from lottery ID to voter address to stake index
    mapping(uint256 => mapping(address => uint256)) public stakes;
    mapping(uint256 => address[]) public stakers;
    mapping(uint256 => uint256) public totalStakes;

    // Counter for vote IDs
    uint256 private _lotteryIdCounter = 1;

    // chainlink vrf variables
    uint256 public s_subscriptionId = 26855092016204205124453749677461341788139777924168207765380961489454212986163;
    bytes32 public s_keyHash = 0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae;
    uint32 public callbackGasLimit = 40000;
    uint16 public requestConfirmations = 3;
    uint32 public numWords = 1;

    // Events
    event LotteryCreated(uint256 indexed lotteryId, uint256 deadline, uint256 stakingDeadline, address initiator);
    event StakeCast(uint256 indexed lotteryId, address indexed staker, uint256 amount);
    event LotteryFinalized(uint256 indexed lotteryId, address winner, uint256 yield);
    event LotteryStakingFinalized(uint256 indexed lotteryId, uint256 amount);
    event WinnerSelected(uint256 indexed lotteryId, address winner, uint256 yield);
    event DiceRolled(uint256 indexed requestId, address indexed roller);
    event DiceLanded(uint256 indexed requestId, uint256 indexed result, uint256 indexed lotteryId);
    event DelayedFunctionExecuted(address indexed caller, uint256 timestamp, uint256 lotteryId);
    event LotteryOwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(address _USDC, address _pool, address _vrfCoordinator) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        USDC = IERC20(_USDC);
        aavePool = IPool(_pool);
        s_vrfCoordinator = IVRFCoordinatorV2Plus(_vrfCoordinator);
        _lotteryOwner = msg.sender;
    }

    /**
     * @dev Throws if called by any account other than the lottery owner.
     */
    modifier onlyLotteryOwner() {
        require(msg.sender == _lotteryOwner, "Caller is not the lottery owner");
        _;
    }

    /**
     * @dev Returns the address of the current lottery owner.
     */
    function lotteryOwner() public view returns (address) {
        return _lotteryOwner;
    }

    /**
     * @dev Transfers lottery ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferLotteryOwnership(address newOwner) public onlyLotteryOwner {
        require(newOwner != address(0), "New owner is the zero address");
        address oldOwner = _lotteryOwner;
        _lotteryOwner = newOwner;
        emit LotteryOwnershipTransferred(oldOwner, newOwner);
    }

    function createLottery(uint256 durationInSeconds, uint256 stakingDurationInSeconds) external onlyLotteryOwner {
        require(durationInSeconds > 0, "Duration must be greater than 0");
        require(stakingDurationInSeconds > 0, "Staking duration must be greater than 0");

        uint256 lotteryId = _lotteryIdCounter++;

        lotteries[lotteryId] = Lottery({
            id: lotteryId,
            deadline: block.timestamp + stakingDurationInSeconds + durationInSeconds,
            stakingDeadline: block.timestamp + stakingDurationInSeconds,
            finalized: false,
            stakingFinalized: false,
            winner: address(0),
            randomRequestId: 0,
            randomNumber: 0,
            yield: 0,
            initiator: msg.sender
        });

        emit LotteryCreated(
            lotteryId,
            block.timestamp + stakingDurationInSeconds + durationInSeconds,
            block.timestamp + stakingDurationInSeconds,
            msg.sender
        );
    }

    function stake(uint256 lotteryId, uint256 amount) external {
        //сюда можно добавить проверку закончился ли стакинг или нет
        Lottery storage lottery = lotteries[lotteryId];

        require(lottery.id != 0, "Lottery does not exist");
        require(!lottery.stakingFinalized, "Lottery staking period has ended");
        require(block.timestamp < lottery.stakingDeadline, "Staking deadline passed");
        require(amount > 0, "Amount must be greater than 0");
        require(USDC.balanceOf(msg.sender) >= amount, "Insufficient USDC balance");

        // Transfer USDC from user to contract
        require(USDC.transferFrom(msg.sender, address(this), amount), "USDC transfer failed");

        // Record the stake
        if (stakes[lotteryId][msg.sender] == 0) {
            stakers[lotteryId].push(msg.sender);
        }
        stakes[lotteryId][msg.sender] += amount;
        totalStakes[lotteryId] += amount;

        emit StakeCast(lotteryId, msg.sender, amount);
    }

    function finalizeStaking(uint256 lotteryId) public {
        Lottery storage lottery = lotteries[lotteryId];
        uint256 amount = totalStakes[lotteryId];

        require(lottery.id != 0, "Lottery does not exist");
        require(!lottery.stakingFinalized, "Lottery staking already finalized");
        require(block.timestamp >= lottery.stakingDeadline, "Lottery staking deadline not passed");

        lottery.stakingFinalized = true;

        // Approve USDC spending for Aave pool
        require(USDC.approve(address(aavePool), amount), "USDC approval failed");

        // Supply USDC to Aave pool
        try aavePool.supply(address(USDC), amount, address(this), 0) {
            // Successfully supplied to Aave
        } catch {
            // If Aave supply fails, revert the transaction
            revert("Failed to supply USDC to Aave pool");
        }

        emit LotteryStakingFinalized(lotteryId, amount);

        // Call rollDice function to get random number for winner selection
        uint256 requestId = rollDice(address(this));
        lotteries[lotteryId].randomRequestId = requestId;
        randomLotteryIds[requestId] = lotteryId;
    }

    function _choseWinner(uint256 lotteryId) internal returns (address) {
        Lottery storage lottery = lotteries[lotteryId];

        require(lottery.id != 0, "Lottery does not exist");
        require(!lottery.finalized, "Lottery already finalized");
        require(lottery.stakingFinalized, "Staking not finalized");
        require(block.timestamp >= lottery.deadline, "Lottery deadline not passed");
        require(lottery.randomNumber != 0, "Random number not set");

        uint256 originalStake = totalStakes[lotteryId];

        // First, select the winner before any external calls
        address[] memory stakersList = stakers[lotteryId];
        require(stakersList.length > 0, "No stakers in lottery");

        // Select random winner from VRF
        uint256 randomValue = lottery.randomNumber;

        // Scale down to range [0, totalStakes[lotteryId]]
        uint256 scaledRandom = randomValue % totalStakes[lotteryId];

        uint256 cumulativeStake = 0;
        address winner;

        // Iterate through stakes to find winner based on weighted random selection
        for (uint256 i = 0; i < stakersList.length; i++) {
            address staker = stakersList[i];
            uint256 stakeAmount = stakes[lotteryId][staker];
            require(stakeAmount > 0, "Invalid stake amount");

            cumulativeStake += stakeAmount;
            if (cumulativeStake > scaledRandom && winner == address(0)) {
                winner = staker;
                break;
            }
        }

        require(winner != address(0), "No winner selected");
        lottery.winner = winner;

        return winner;
    }

    function _withdrawYield(uint256 lotteryId) internal returns (uint256) {
        uint256 originalStake = totalStakes[lotteryId];

        try aavePool.withdraw(address(USDC), type(uint256).max, address(this)) {
            // Successfully withdrawn from Aave
        } catch {
            revert("Failed to withdraw from Aave pool");
        }
        // Get the actual amount withdrawn
        uint256 amountWithYield = USDC.balanceOf(address(this));
        require(amountWithYield >= originalStake, "Yield cannot be negative");
        uint256 yield = amountWithYield - originalStake;

        return yield;
    }

    function _stakeBackTransfer(address staker, uint256 userStake) internal nonReentrant {
        require(USDC.transfer(staker, userStake), "USDC transfer failed");
    }

    function finalizeLottery(uint256 lotteryId) public {
        Lottery storage lottery = lotteries[lotteryId];

        require(lottery.id != 0, "Lottery does not exist");
        require(lottery.stakingFinalized, "Staking not finalized");
        require(block.timestamp >= lottery.deadline, "Lottery deadline not passed");

        if (lottery.winner == address(0)) {
            lottery.winner = _choseWinner(lotteryId);
            emit WinnerSelected(lotteryId, lottery.winner, lottery.yield);
        }

        // Withdraw from Aave after winner selection
        if (lottery.yield == 0) {
            lottery.yield = _withdrawYield(lotteryId);

            lottery.finalized = true;
            emit LotteryFinalized(lotteryId, lottery.winner, lottery.yield);
        }
    }

    function takeWinnings(uint256 lotteryId) public {
        Lottery storage lottery = lotteries[lotteryId];

        require(lottery.id != 0, "Lottery does not exist");
        require(lottery.stakingFinalized, "Staking not finalized");
        require(block.timestamp >= lottery.deadline, "Lottery deadline not passed");

        uint256 userStake = stakes[lotteryId][msg.sender];
        require(userStake > 0, "User has no stake in this lottery or already took winnings");

        // Send winnings to user
        if (msg.sender == lottery.winner) {
            _stakeBackTransfer(lottery.winner, userStake + lottery.yield);
        } else {
            _stakeBackTransfer(msg.sender, userStake);
        }
        stakes[lotteryId][msg.sender] = 0;
    }

    function isLotteryActive(uint256 lotteryId) external view returns (bool) {
        Lottery storage lottery = lotteries[lotteryId];
        return lottery.id != 0 && !lottery.finalized && block.timestamp < lottery.deadline;
    }

    /**
     * @dev Get the number of votes created
     * @return Number of votes
     */
    function getLotteryCount() external view returns (uint256) {
        return _lotteryIdCounter - 1;
    }

    /**
     * @notice Requests randomness
     * @dev Warning: if the VRF response is delayed, avoid calling requestRandomness repeatedly
     * as that would give miners/VRF operators latitude about which VRF response arrives first.
     * @dev You must review your implementation details with extreme care.
     *
     * @param roller address of the roller
     */
    function rollDice(address roller) internal returns (uint256 requestId) {
        // Will revert if subscription is not set and funded.
        requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: s_keyHash,
                subId: s_subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: numWords,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    // Set nativePayment to true to pay for VRF requests with Sepolia ETH instead of LINK
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                )
            })
        );
        emit DiceRolled(requestId, roller);
    }

    /**
     * @notice Callback function used by VRF Coordinator to return the random number to this contract.
     *
     * @dev Some action on the contract state should be taken here, like storing the result.
     * @dev WARNING: take care to avoid having multiple VRF requests in flight if their order of arrival would result
     * in contract states with different outcomes. Otherwise miners or the VRF operator would could take advantage
     * by controlling the order.
     * @dev The VRF Coordinator will only send this function verified responses, and the parent VRFConsumerBaseV2
     * contract ensures that this method only receives randomness from the designated VRFCoordinator.
     *
     * @param requestId uint256
     * @param randomWords  uint256[] The random result returned by the oracle.
     */
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        // Get random value from VRF
        uint256 randomValue = randomWords[0];
        // Store random value in lottery
        uint256 lotteryId = randomLotteryIds[requestId];
        lotteries[lotteryId].randomNumber = randomValue;

        emit DiceLanded(requestId, randomValue, lotteryId);
    }

    function fulfillRandomWords_mock(uint256 requestId, uint256[] calldata randomWords) external {
        fulfillRandomWords(requestId, randomWords);
    }

    function checkUpkeep(bytes calldata /* checkData */ )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory /* performData */ )
    {
        upkeepNeeded = false;

        for (uint256 i = 1; i < _lotteryIdCounter; i++) {
            if (
                lotteries[i].id != 0 && !lotteries[i].finalized && block.timestamp >= lotteries[i].deadline
                    && lotteries[i].randomNumber != 0
            ) {
                upkeepNeeded = true;
                break;
            } else if (
                lotteries[i].id != 0 && !lotteries[i].finalized && block.timestamp >= lotteries[i].stakingDeadline
                    && !lotteries[i].stakingFinalized
            ) {
                upkeepNeeded = true;
                break;
            }
        }
    }

    function performUpkeep(bytes calldata /* performData */ ) external override {
        // require(block.timestamp >= lastFunctionExecutionTime + delay, "Delay period not met");
        for (uint256 i = 1; i < _lotteryIdCounter; i++) {
            if (
                lotteries[i].id != 0 && !lotteries[i].finalized && block.timestamp >= lotteries[i].deadline
                    && lotteries[i].randomNumber != 0
            ) {
                emit DelayedFunctionExecuted(msg.sender, block.timestamp, i);
                finalizeLottery(i);
                break;
            } else if (
                lotteries[i].id != 0 && !lotteries[i].finalized && block.timestamp >= lotteries[i].stakingDeadline
                    && !lotteries[i].stakingFinalized
            ) {
                emit DelayedFunctionExecuted(msg.sender, block.timestamp, i);
                finalizeStaking(i);
                break;
            }
        }
    }
}
