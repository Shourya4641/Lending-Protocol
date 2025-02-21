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

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from
    "../lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

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

    //////////////////////////// STATE VARIABLES ///////////////////////////////

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;

    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    //////////////////////////// EVENTS ///////////////////////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed user, address indexed token, uint256 indexed amount);

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

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__tokenAddressesAndPriceFeedAddressesLengthMustBeSame();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    //////////////////////////// EXTERNAL FUNCTIONS /////////////////////////////

    /**
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param collateralAmount The amount of collateral to deposit
     * @param amountDscToMint The amount of DSC to mint
     * @notice this function will deposit collateral and mint DSC in one transaction
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

    /**
     * @param tokenCollateralAddress The collateral address to redeem
     * @param collateralAmount The amount of collateral to redeem
     * @param amountDscToBurn The amount of DSC to burn
     * @notice this function will redeem collateral and burn DSC in one transaction
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 collateralAmount, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, collateralAmount);
        // redeemCollateral checks the health factor...
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 collateralAmount)
        public
        moreThanZero(collateralAmount)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += collateralAmount;
        emit CollateralRedeemed(msg.sender, tokenCollateralAddress, collateralAmount);

        bool success = IERC20(tokenCollateralAddress).transfer(msg.sender, collateralAmount);

        if (!success) {
            revert DSCEngine__TransferFailed();
        }

        _revertIfHealthFactorIsBroken(msg.sender);
    }

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

    function burnDsc(uint256 amount) public moreThanZero(amount) nonReentrant {
        s_DSCMinted[msg.sender] -= amount;

        bool success = i_dsc.transferFrom(msg.sender, address(this), amount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amount);
        _revertIfHealthFactorIsBroken(msg.sender); // may not reach here!
    }

    function liquidate() external {}

    function getHealthFactor() external view {}

    //////////////////////////// INTERNAL & PRIVATE VIEW FUNCTIONS /////////////////////////////

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
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
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    //////////////////////////// PUBLIC & EXTERNAL VIEW FUNCTIONS /////////////////////////////

    function getAccountCollateralValue(address user) public view returns (uint256 collateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            collateralValueInUsd = getUsdValue(token, amount);
        }
        return collateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256 usdValue) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }
}
