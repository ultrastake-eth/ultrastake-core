pragma solidity >=0.8.0 <0.9.0;
//SPDX-License-Identifier: MIT


/**
  *
  *
  *=----======-------------=================================--------------======-------=*
  #                                                                                     #
  #   ██╗   ██╗██╗  ████████╗██████╗  █████╗ ███████╗████████╗ █████╗ ██╗  ██╗███████╗  #
  #   ██║   ██║██║  ╚══██╔══╝██╔══██╗██╔══██╗██╔════╝╚══██╔══╝██╔══██╗██║ ██╔╝██╔════╝  #
  #   ██║   ██║██║     ██║   ██████╔╝███████║███████╗   ██║   ███████║█████╔╝ █████╗    #
  #   ██║   ██║██║     ██║   ██╔══██╗██╔══██║╚════██║   ██║   ██╔══██║██╔═██╗ ██╔══╝    #
  #   ╚██████╔╝███████╗██║   ██║  ██║██║  ██║███████║   ██║   ██║  ██║██║  ██╗███████╗  #
  #    ╚═════╝ ╚══════╝╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝  #
  #                                                                                     #
  *=----=====---------===| Stake ETH + Win ETH + Never Lose |===-----------=======-----=*
  *
  *
  */



import "./interface/UltraLPInterface.sol";
import "./interface/RocketStorageInterface.sol";
import "./interface/RocketDepositPoolInterface.sol";
import "./interface/RocketTokenRETHInterface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/VRFV2WrapperConsumerBase.sol";
import "@chainlink/contracts/src/v0.8/AutomationCompatible.sol";



contract UltraStake is VRFV2WrapperConsumerBase, AutomationCompatibleInterface, Pausable, Ownable, ReentrancyGuard {


  /* ============ Contract State ============ */

  RocketStorageInterface rocketStorage = RocketStorageInterface(address(0));

  address public UltraLP;

  uint256 public totalEthStaked = 0;

  uint256 public prizePerWinner = 1 ether;

  uint256 public maxStake = 500 ether;

  struct DepositStatus {
    uint256 ETHstaked;
    uint256 rETHreceived;
  }

  struct StructStaker {
    uint256 balance;
    uint256 index;
    bool exists;
    DepositStatus[] depositsToCheck;
  }

  mapping(address => StructStaker) public stakers;
  address[] public addressIndexes;

  // ChainLink VRF + Automation
  uint32 public callbackGasLimit = 500000;
  uint16 public requestConfirmations = 3;
  uint32 public numWinners = 1;
  bool public upkeepInProgress;

  uint16 constant BASIS_POINTS = 10000;
  uint16 public ultraPoints;
  address recipient;

  struct RequestStatus {
    uint256 paid;   // amount paid in LINK
    bool fulfilled; // whether the request has been successfully fulfilled
    uint256[] randomWords;
    uint256 prizePerWinner;
    uint32 numWinners;
  }

  mapping(uint256 => RequestStatus) public s_requests; /* requestId --> requestStatus */





  /* ============ Contract Events ============ */

  event RequestWinners(uint256 requestId, uint32 numWinners, uint256 prizePerWinner);
  event Winner(uint256 requestId, uint256 randomness, address indexed staker, uint256 amountETH);
  event EthDeposit(address staker, uint256 amountETH, uint256 amountRETH);
  event rEthDeposit(address staker, uint256 amountETH, uint256 amountRETH);
  event EthWithdraw(address staker, uint256 amountETH, uint256 amountRETH);
  event rEthWithdraw(address staker, uint256 amountETH, uint256 amountRETH);





  /* ============ Contract Constructor ============ */

  constructor(address _rocketStorageAddress, address _recipient, uint16 _points)
      VRFV2WrapperConsumerBase(
          0x514910771AF9Ca656af840dff83E8264EcF986CA, // LINK Token
          0x5A861794B927983406fCE1D062e00b9368d97Df6  // VFR V2 wrapper
      )
  {
      rocketStorage = RocketStorageInterface(_rocketStorageAddress);
      ultraPoints = _points;
      recipient = _recipient;
      addStaker(_recipient);
  }





  /* ============ Contract Functions ============ */

  // Function to receive Eth. Necessary for rETH to ETH burn on withdraw.
  receive() external payable {}




  // Add staker to contract. If your balance is greater than 0, you have a chance at winning prizes.
  function addStaker(address _staker) private {
    addressIndexes.push(_staker);
    stakers[_staker].index = addressIndexes.length-1;
    stakers[_staker].exists = true;
  }




  // Add to Pool (Stake ETH)
  // @param asReth: wether you are depositing rETH or ETH
  // @param rEthAmt to stake if staking rETH. The ETH value of the rETH sent will be added to balance.
  function addToPool(bool asReth, uint256 rEthAmt, bool useUltraLP) external nonReentrant whenNotPaused payable {
    require(!upkeepInProgress, "Prize distribution in progress");

    uint256 ethValue;
    uint256 rEthValue;

    // Load rETH contract
    address rocketTokenRETHAddress = rocketStorage.getAddress(keccak256(abi.encodePacked("contract.address", "rocketTokenRETH")));
    RocketTokenRETHInterface rocketTokenRETH = RocketTokenRETHInterface(rocketTokenRETHAddress);

    if (asReth) {
      require(msg.value == 0, "Do not send ETH");
      // msg.sender must have first approved using their rETH to transfer
      require(rocketTokenRETH.transferFrom(msg.sender, address(this), rEthAmt), "Could not transfer rETH");
      ethValue = rocketTokenRETH.getEthValue(rEthAmt);
      rEthValue = rEthAmt;
      emit rEthDeposit(msg.sender, ethValue, rEthValue);
    } else {
      // Forward deposit to RP & get amount of rETH minted
      uint256 rethBalance1 = rocketTokenRETH.balanceOf(address(this));
      if (useUltraLP) {
        UltraLPInterface(UltraLP).getReth{value: msg.value}();
      } else {
        // Load RocketPool Deposit contract
        address rocketDepositPoolAddress = rocketStorage.getAddress(keccak256(abi.encodePacked("contract.address", "rocketDepositPool")));
        RocketDepositPoolInterface rocketDepositPool = RocketDepositPoolInterface(rocketDepositPoolAddress);
        rocketDepositPool.deposit{value: msg.value}();
      }
      uint256 rethBalance2 = rocketTokenRETH.balanceOf(address(this));
      require(rethBalance2 > rethBalance1, "No rETH was minted");
      rEthValue = rethBalance2 - rethBalance1;
      ethValue = msg.value;
      emit EthDeposit(msg.sender, ethValue, rEthValue);
    }

    // Update staker's balance
    if (!stakers[msg.sender].exists) {
      addStaker(msg.sender);
    }
    stakers[msg.sender].balance += ethValue;
    require(stakers[msg.sender].balance <= maxStake, "Exceeds maximum stake");
    stakers[msg.sender].depositsToCheck.push(DepositStatus(ethValue, rEthValue));

    // Update total eth staked:
    totalEthStaked += ethValue;
  }




  // Simple getter function to get a depositsToCheck
  function getDepositToCheck(address _staker, uint256 index) public view returns (DepositStatus memory) {
    return stakers[_staker].depositsToCheck[index];
  }





  // Check that the address provided can make a withdraw.
  // In order to withdraw your balance, we must ensure that the rETH we got from your deposits is worth at
  // least what was deposited. RocketPool deposits and DEX swaps have a small fee which we have to account for.
  function checkIfCanWithdraw(address _staker) public view returns (bool) {
    // Load rETH contract
    address rocketTokenRETHAddress = rocketStorage.getAddress(keccak256(abi.encodePacked("contract.address", "rocketTokenRETH")));
    RocketTokenRETHInterface rocketTokenRETH = RocketTokenRETHInterface(rocketTokenRETHAddress);
    // Check each depositsToCheck.
    bool canWithdraw = true;
    uint256 ethValueReth;
    for (uint256 i; i < stakers[_staker].depositsToCheck.length; ++i) {
      ethValueReth = rocketTokenRETH.getEthValue(stakers[_staker].depositsToCheck[i].rETHreceived);
      if (ethValueReth <= stakers[_staker].depositsToCheck[i].ETHstaked) {
        canWithdraw = false;
        break;
      }
    }
    return canWithdraw;
  }





  // Withdraw your balance (un-stake) from the pool.
  // If you choose to withdraw as rETH, you will get the rETH equivalent of the amountEth requested.
  function withdrawFromPool(uint256 amountEth, bool asReth, bool useUltraLP) nonReentrant external {
    require(!upkeepInProgress, "Prize distribution in progress");
    require(amountEth > 0, "Invalid amount");
    require(stakers[msg.sender].balance >= amountEth, 'Insufficient balance');
    require(checkIfCanWithdraw(msg.sender), "Cannot withdraw yet.");

    // Load rETH contracts
    address rocketTokenRETHAddress = rocketStorage.getAddress(keccak256(abi.encodePacked("contract.address", "rocketTokenRETH")));
    RocketTokenRETHInterface rocketTokenRETH = RocketTokenRETHInterface(rocketTokenRETHAddress);

    // Get the rETH value of the withdraw amount requested
    uint256 rEthAmt = rocketTokenRETH.getRethValue(amountEth);
    // Often missing 1 wei due to integer math
    while (rocketTokenRETH.getEthValue(rEthAmt) < amountEth) {
      rEthAmt += 1;
    }

    // Update balance and total eth staked:
    stakers[msg.sender].balance -= amountEth;
    totalEthStaked -= amountEth;

    if (asReth) {
      // Transfer rETH to caller
      require(rocketTokenRETH.transfer(msg.sender, rEthAmt), "rETH was not transferred to caller");
      emit rEthWithdraw(msg.sender, amountEth, rEthAmt);
    } else {
      // Burn rETH to ETH
      uint256 ethBalanceBefore = address(this).balance;
      if (useUltraLP) {
        require(rocketTokenRETH.approve(UltraLP, rEthAmt));
        UltraLPInterface(UltraLP).getEth(rEthAmt);
      } else {
        rocketTokenRETH.burn(rEthAmt);
      }
      uint256 ethReceived = address(this).balance - ethBalanceBefore;
      require(ethReceived >= amountEth, 'Insuficient ETH from burn');
      // Send ETH to caller
      (bool success, ) = payable(msg.sender).call{value: amountEth}("");
      require(success, 'Failed to send Ether');
      emit EthWithdraw(msg.sender, amountEth, rEthAmt);
    }

    // Reset staker's depositsToCheck.
    delete stakers[msg.sender].depositsToCheck;
  }




  // Returns total superflous rewards.
  function checkTotalRewards(bool asReth) private view returns (uint256) {
    address rocketTokenRETHAddress = rocketStorage.getAddress(keccak256(abi.encodePacked("contract.address", "rocketTokenRETH")));
    RocketTokenRETHInterface rocketTokenRETH = RocketTokenRETHInterface(rocketTokenRETHAddress);

    uint256 rEthBalance = rocketTokenRETH.balanceOf(address(this));
    uint256 rEthValueTotal = rocketTokenRETH.getRethValue(totalEthStaked);
    uint256 rEthRewards = 0;
    if (rEthBalance > rEthValueTotal) {
      rEthRewards = rEthBalance - rEthValueTotal;
    }
    if (asReth) {
      return rEthRewards;
    } else {
      return rocketTokenRETH.getEthValue(rEthRewards);
    }
  }




  // Returns available rewards for prize distribution.
  function checkAvailableRewards(bool asReth) public view returns (uint256) {
    uint256 availableRewards = checkTotalRewards(asReth);
    return availableRewards * (BASIS_POINTS - ultraPoints) / BASIS_POINTS;
  }







  /* ============ Generating Random Winners ============ */

  // @dev Check if we are ready to award a prize.
  function checkUpkeep(bytes calldata /* checkData */) external view override returns (bool upkeepNeeded, bytes memory /* performData */) {
    uint256 availableRewards = checkAvailableRewards(false);
    bool prizeReady = (availableRewards / numWinners) > prizePerWinner;
    upkeepNeeded = (prizeReady && !upkeepInProgress && !paused());
  }




  // @dev If we're ready, request randomness for each number of winners.
  function performUpkeep(bytes calldata /* performData */) external whenNotPaused nonReentrant override {
    require(!upkeepInProgress, 'Already in progress');
    uint256 availableRewards = checkAvailableRewards(false);
    require((availableRewards / numWinners) > prizePerWinner, 'Prize not ready');

    upkeepInProgress = true;

    uint256 requestId = requestRandomness(callbackGasLimit, requestConfirmations, numWinners);

    s_requests[requestId] = RequestStatus({
        paid: VRF_V2_WRAPPER.calculateRequestPrice(callbackGasLimit),
        fulfilled: false,
        randomWords: new uint256[](numWinners),
        prizePerWinner: prizePerWinner,
        numWinners: numWinners
    });

    emit RequestWinners(requestId, numWinners, prizePerWinner);
  }




  // @dev Callback function used by VRF Coordinator. Picking winners and awarding prizes.
  function fulfillRandomWords(uint256 _requestId, uint256[] memory randomWords) internal override {
    require(upkeepInProgress, 'Impossible!');
    require(s_requests[_requestId].paid > 0 && !s_requests[_requestId].fulfilled, 'Request not found');

    uint256 totalRewards = checkTotalRewards(false);
    uint256 remaining = totalRewards;
    uint256 totalPrize = totalRewards * (BASIS_POINTS - ultraPoints) / BASIS_POINTS;
    uint256 winnersPrize = s_requests[_requestId].prizePerWinner;
    uint32 _numWinners = s_requests[_requestId].numWinners;

    require((totalPrize / _numWinners) > winnersPrize, "Prize not ready");

    s_requests[_requestId].fulfilled = true;
    s_requests[_requestId].randomWords = randomWords;

    uint256 _totalStaked = totalEthStaked;
    uint256 randomNormalizedFraction;
    uint256 normalizedFractionSoFar;
    uint256 winnerIdx;

    address[] memory _addressIndexes = addressIndexes;

    address[] memory winners = new address[](_numWinners);


    // Pick winners for each random number
    for (uint32 i; i < _numWinners; ++i) {
      randomNormalizedFraction = ((randomWords[i] % _totalStaked) * 1 ether) / _totalStaked;
      normalizedFractionSoFar = 0;
      winnerIdx = 0;

      // If the randomNormalizedFraction falls in your fraction you are the winner.
      while (randomNormalizedFraction >= normalizedFractionSoFar) {
        normalizedFractionSoFar += (stakers[_addressIndexes[winnerIdx]].balance * 1 ether) / _totalStaked;
        ++winnerIdx;
      }

      require(_addressIndexes[winnerIdx - 1] != address(0), 'Error picking winner');
      winners[i] = _addressIndexes[winnerIdx - 1];
    }

    // Give prize to each winner
    for (uint32 j; j < _numWinners; ++j) {
      stakers[winners[j]].balance += winnersPrize;
      remaining -= winnersPrize;
      emit Winner(_requestId, randomWords[j], winners[j], winnersPrize);
    }

    require(remaining >= 0, 'Error balances');
    stakers[recipient].balance += remaining;

    totalEthStaked += totalRewards;
    upkeepInProgress = false;
  }





  /* ============ Adjustable Contract Parameters ============ */

  // @dev can pause awarding of prizes and adding to pool. Withdrawing is always available.
  function pause() external onlyOwner {
    _pause();
  }

  function unpause() external onlyOwner {
    _unpause();
  }

  // @dev only in case something gets stuck during awarding of prizes.
  function setUpkeepInProgress(bool status) external onlyOwner {
    upkeepInProgress = status;
  }

  // @dev this contract should always have a maintainer.
  function renounceOwnership() override onlyOwner public {
    require(false, 'This contract requires an owner.');
  }

  function setPrizePerWinner(uint256 _prize) external onlyOwner {
    prizePerWinner = _prize;
  }

  function setUltraPoints(uint16 _points) external onlyOwner {
    require(_points <= BASIS_POINTS, 'Invalid points');
    ultraPoints = _points;
  }

  function setNumWinners(uint32 _numWinners) external onlyOwner {
    require(_numWinners > 0, 'Invalid number');
    numWinners = _numWinners;
  }

  function setRecipient(address _recipient) external onlyOwner {
    recipient = _recipient;
    if (!stakers[_recipient].exists) {
      addStaker(_recipient);
    }
  }

  function setCallbackGasLimit(uint32 _callbackGasLimit) external onlyOwner {
    callbackGasLimit = _callbackGasLimit;
  }

  function setRequestConfirmations(uint16 _requestConfirmations) external onlyOwner {
    requestConfirmations = _requestConfirmations;
  }

  function setMaxStake(uint256 _maxStake) external onlyOwner {
    maxStake = _maxStake;
  }

  function setUltraLP(address _UltraLP) external onlyOwner {
    UltraLP = _UltraLP;
  }

}
