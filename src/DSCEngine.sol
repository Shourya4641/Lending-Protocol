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
 * @title DSCEngine
 * @author Shourya
 *  
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1:1 ratio with respect to the dollars.
 * This stablecoin has properties
 * - Exogenous collateral
 * - Dollar pegged
 * - Algorithmically stable
 * 
 * Our DSC system shuold always be overcollaterized. At no point, should the value of all colateral <= the $backed value of all the DSC.
 * 
 * @notice This contract is the core of the DSC system. It handles all the logic for mining and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is loosely based on the MakerDAO DSS (DAI) system
 */
contract DSCEngine {

    function depositCollateralAndMintDsc() external {}

    function depositCollateral() external {}

    function redeemCollateralForDsc() external {}
    
    function redeemCollateral() external {}

    function mintDsc() external {}

    function burnDsc() external {}

    function liquidate() external {}

    function getHealthFactor() external view {}


}