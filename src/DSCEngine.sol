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

import {console2} from "forge-std/console2.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from
    "../lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "../src/libraries/OracleLib.sol";

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
contract DSCEngine is ReentrancyGuard {
    //////////////////////////// ERRORS ///////////////////////////////

    error DSCEngine__MustBeMoreThanZero();
    error DSCEngine__tokenAddressesAndPriceFeedAddressesLengthMustBeSame();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 userHealthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorIsNotBroken();
    error DSCEngine__HealthFactorIsNotImproved();

    //////////////////////////// TYPES ///////////////////////////////
    using OracleLib for AggregatorV3Interface;

    //////////////////////////// STATE VARIABLES ///////////////////////////////

    DecentralizedStableCoin private immutable i_dsc;

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% liquidation bonus to the liquidator

    /// @dev Mapping of token address to price feed address
    mapping(address token => address priceFeed) private s_priceFeeds;

    /// @dev Amount of collateral deposited by the user
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;

    /// @dev Amount of DSC minted by the user
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;

    /// @dev List of collateral tokens in our protocol
    address[] private s_collateralTokens;

    //////////////////////////// EVENTS ///////////////////////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    //////////////////////////// MODIFIERS ////////////////////////////

    modifier moreThanZero(uint256 _amount) {
        if (_amount == 0) {
            revert DSCEngine__MustBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedTokens(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    //////////////////////////// FUNCTIONS /////////////////////////////

    constructor(address[] memory collateralTokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (collateralTokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__tokenAddressesAndPriceFeedAddressesLengthMustBeSame();
        }

        for (uint256 i = 0; i < collateralTokenAddresses.length; i++) {
            s_priceFeeds[collateralTokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(collateralTokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    //////////////////////////// EXTERNAL FUNCTIONS /////////////////////////////

    /**
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param collateralAmount The amount of collateral to deposit
     * @param amountDscToMint The amount of DSC to mint
     * @notice This function will deposit collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 collateralAmount,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, collateralAmount);
        mintDsc(amountDscToMint);
    }

    /**
     * @param tokenCollateralAddress The collateral address to redeem
     * @param collateralAmount The amount of collateral to redeem
     * @param amountDscToBurn The amount of DSC to burn
     * @notice this function will redeem collateral and burn DSC in one transaction
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 collateralAmount, uint256 amountDscToBurn)
        external
    {
        _burnDsc(msg.sender, msg.sender, amountDscToBurn);
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, collateralAmount);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice This function will redeem user's collateral
     * @notice Collateral cannot be redeemed untill the minted DSC is burnt
     * @param tokenCollateralAddress The ERC20 token address of the collateral user is redeeming
     * @param collateralAmount The amount of collateral user is redeeming
     */
    function redeemCollateral(address tokenCollateralAddress, uint256 collateralAmount)
        public
        moreThanZero(collateralAmount)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, collateralAmount);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @dev In case user is afraid of getting liquidated then the user can burn their DSC to keep their collateral safe
     * @param amount The amount of DSC to burn
     */
    function burnDsc(uint256 amount) public moreThanZero(amount) nonReentrant {
        _burnDsc(msg.sender, msg.sender, amount);
        _revertIfHealthFactorIsBroken(msg.sender); // may not reach here!
    }

    /**
     * @notice Liquidator will get liquidation bonus
     * @notice The user can be partially liquidated
     * @notice The protocol is assumed to be 150% overcollateralized at all times to stay safe
     * @notice The protocol cannot incentivize the liquidator in case it is 100% or less collateralized
     * @param collateral The address of the ERC20 collateral token address to liquidate
     * @param user The address of the user whose health factor is broken
     * @param debtToCover The amount of DSC to burn to improve the user's health factor
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        // need to check the health factor of the user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsNotBroken();
        }

        // bad user: $140 ETH -- $100 DSC
        // debtToCover: $100 DSC
        // $100 DSC = ?? ETH
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);

        // 10% bonus should be given to the liquidators
        uint256 liquidationBonus = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + liquidationBonus;

        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);

        _burnDsc(user, msg.sender, debtToCover);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorIsNotImproved();
        }

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    //////////////////////////// PUBLIC FUNCTIONS /////////////////////////////

    /**
     * @notice follows CEI
     * @notice User must have more collateral value than the minimum threshold
     * @param amountDscToMint The amount of DecentralizedStableCoin to mint
     *
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;

        // if minted token value is more than the collateral then the process should be reverted
        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    /**
     * @notice follows CEI
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param collateralAmount The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 collateralAmount)
        public
        moreThanZero(collateralAmount)
        isAllowedTokens(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += collateralAmount;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, collateralAmount);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), collateralAmount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    //////////////////////////// PRIVATE FUNCTIONS /////////////////////////////

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 collateralAmount)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= collateralAmount;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, collateralAmount);

        bool success = IERC20(tokenCollateralAddress).transfer(to, collateralAmount);

        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @dev low-level internal function, do not call unless the function calling it is checking for the health factor being broken
     */
    function _burnDsc(address onBehalfOf, address dscFrom, uint256 dscAmountToBurn) private {
        s_DSCMinted[onBehalfOf] -= dscAmountToBurn;

        bool success = i_dsc.transferFrom(dscFrom, address(this), dscAmountToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(dscAmountToBurn);
    }

    //////////////////////////// PRIVATE & INTERNAL VIEW & PURE FUNCTIONS /////////////////////////////

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
        return (totalDscMinted, collateralValueInUsd);
    }

    /**
     *
     * @param user address of the user whose health factor is to be calculated
     * returns how close to liquidation a user is
     * if a user health factor goes below 1, then they can be liquidated
     */
    function _healthFactor(address user) internal view returns (uint256 healthFactor) {
        // total DSC minted
        // total collateral VALUE
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256 healthFactor)
    {
        if (totalDscMinted == 0) {
            return type(uint256).max;
        }
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    function _getUsdValue(address token, uint256 amount) internal view returns (uint256 usdValue) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    //////////////////////////// EXTERNAL & PUBLIC VIEW & PURE FUNCTIONS /////////////////////////////

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        public
        pure
        returns (uint256 healthFactor)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getAccountInformation(address user)
        public
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        return _getAccountInformation(user);
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256 usdValue) {
        return _getUsdValue(token, amount);
    }

    function getCollateralBalanceOfUser(address user, address token) public view returns (uint256 amount) {
        return s_collateralDeposited[user][token];
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei)
        public
        view
        returns (uint256 tokenAmountFromDebtCovered)
    {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return (usdAmountInWei * PRECISION) / ((uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    function getPrecision() public pure returns (uint256 precision) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() public pure returns (uint256 precision) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() public pure returns (uint256 threshold) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationPrecision() public pure returns (uint256 precision) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() public pure returns (uint256 minHealthFactor) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() public view returns (address[] memory collateralTokens) {
        return s_collateralTokens;
    }

    function getDsc() public view returns (address dsc) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) public view returns (address priceFeed) {
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) public view returns (uint256 healthFactor) {
        return _healthFactor(user);
    }
}
