pragma solidity >=0.8.0 <0.9.0;
//SPDX-License-Identifier: MIT

interface UltraLPInterface {
  function getReth() external payable;
  function getEth(uint256 amountReth) external;
}
