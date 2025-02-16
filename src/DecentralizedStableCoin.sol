//SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity 0.8.24;

/**
 * @title DecentralizedStableCoin
 * @author Shourya Sarkar
 * Collatorals: Exogenous (ETH and BTC)
 * Minting: Algorithmic
 * Relative Stability: Pegged to USD
 * 
 * This is a contract meant to be governed by DSCEngine. This contract is just the ERC20 implementation of our stablecoin system. 
 */
contract DecentralizedStableCoin {
    constructor() {
        
    }
}