//SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../../test/mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig config;
    address wethUsdPriceFeed;
    address wbtcUsdPriceFeed;
    address weth;
    address wbtc;
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 20 ether;
    uint256 public constant AMOUNT_DSC_TO_MINT = 4 ether;
    uint256 public constant AMOUNT_DSC_TO_BURN = 4 ether;
    uint256 public constant AMOUNT_COLLATERAL_TO_REDEEM = 0.5 ether;
    uint256 public constant AMOUNT_COLLATERAL_TO_BREAK_HEALTH_FACTOR = 11 ether;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dscEngine, config) = deployer.run();
        (wethUsdPriceFeed, wbtcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(weth).mint(LIQUIDATOR, STARTING_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(LIQUIDATOR, STARTING_ERC20_BALANCE);
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    ////////////////////////CONSTRUCTOR TESTS////////////////////////
    function testRevertsIfTokenAddressesLengthNotEqualToPriceFeedAddressesLength() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(wethUsdPriceFeed);
        priceFeedAddresses.push(wbtcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__tokenAddressesAndPriceFeedAddressesLengthMustBeSame.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    ////////////////////////PRICE TESTS////////////////////////

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;

        (, int256 price,,,) = MockV3Aggregator(wethUsdPriceFeed).latestRoundData();
        uint256 expectedUsd = (uint256(price) * ADDITIONAL_FEED_PRECISION * ethAmount) / PRECISION;
        uint256 actualUsd = dscEngine.getUsdValue(weth, ethAmount);

        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;

        (, int256 price,,,) = MockV3Aggregator(wethUsdPriceFeed).latestRoundData();
        uint256 expectedWethAmount = (usdAmount * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);

        uint256 actualWethAmount = dscEngine.getTokenAmountFromUsd(weth, usdAmount);

        assertEq(expectedWethAmount, actualWethAmount);
    }

    ////////////////////////DEPOSIT COLLATERAL TESTS////////////////////////

    function testRevertsIfCollateralIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateralToken() public {
        ERC20Mock randomToken = new ERC20Mock("RandomToken", "RandomToken", USER, AMOUNT_COLLATERAL);

        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dscEngine.depositCollateral(address(randomToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndGetAccountInfo() public {
        vm.startPrank(USER);

        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        vm.expectEmit(true, true, true, false, address(dscEngine));
        emit DSCEngine.CollateralDeposited(USER, weth, AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedCollateralValueInUsd = dscEngine.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assertEq(expectedTotalDscMinted, totalDscMinted);
        assertEq(expectedCollateralValueInUsd, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCanDepositMultipleTokensAsCollateral() public {
        vm.startPrank(USER);

        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        ERC20Mock(wbtc).approve(address(dscEngine), AMOUNT_COLLATERAL);

        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(wbtc, AMOUNT_COLLATERAL);

        (, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);

        uint256 expectedCollateralValueInUsd =
            dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL) + dscEngine.getUsdValue(wbtc, AMOUNT_COLLATERAL);

        assertEq(collateralValueInUsd, expectedCollateralValueInUsd);

        vm.stopPrank();
    }

    ////////////////////////MINT DSC TOKENS TESTS////////////////////////

    function testRevertsIfMintAmountZero() public depositedCollateral {
        vm.startPrank(USER);

        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.mintDsc(0);

        vm.stopPrank();
    }

    function testCannotMintWithoutCollateral() public {
        vm.startPrank(USER);

        uint256 mintAmount = 1000 ether;

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 0));
        dscEngine.mintDsc(mintAmount);

        vm.stopPrank();
    }

    function testMintDscUpdatesState() public depositedCollateral {
        vm.startPrank(USER);

        dscEngine.mintDsc(AMOUNT_DSC_TO_MINT);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);

        assertEq(userBalance, AMOUNT_DSC_TO_MINT);
    }

    function testRevertsIfMintBreaksHealthFactor() public depositedCollateral {
        (, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);
        uint256 amountToMint = ((collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION) + 5;

        vm.startPrank(USER);

        vm.expectRevert();
        dscEngine.mintDsc(amountToMint);

        vm.stopPrank();
    }

    function testCanMintMaximumDsc() public depositedCollateral {
        (, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);
        uint256 amountToMint = collateralValueInUsd * LIQUIDATION_THRESHOLD / LIQUIDATION_PRECISION;

        vm.startPrank(USER);
        dscEngine.mintDsc(amountToMint);

        uint256 userDscBalance = dsc.balanceOf(USER);
        assertEq(userDscBalance, amountToMint);

        vm.stopPrank();
    }

    ////////////////////////BURN DSC TOKENS TESTS////////////////////////

    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(USER);

        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.burnDsc(0);

        vm.stopPrank();
    }

    function testBurnDscFailsWithoutAllowance() public depositedCollateral {
        vm.startPrank(USER);

        dscEngine.mintDsc(AMOUNT_DSC_TO_MINT);

        vm.expectRevert();
        dscEngine.burnDsc(AMOUNT_DSC_TO_BURN);

        vm.stopPrank();
    }

    function testBurnDscSucceedsWithAllowance() public depositedCollateral {
        vm.startPrank(USER);

        dscEngine.mintDsc(AMOUNT_DSC_TO_MINT);

        dsc.approve(address(dscEngine), AMOUNT_DSC_TO_BURN);
        dscEngine.burnDsc(AMOUNT_DSC_TO_BURN);

        uint256 userDscBalance = dsc.balanceOf(USER);
        assertEq(userDscBalance, AMOUNT_DSC_TO_MINT - AMOUNT_DSC_TO_BURN);

        vm.stopPrank();
    }

    function testCanBurnAllDsc() public depositedCollateral {
        vm.startPrank(USER);

        dscEngine.mintDsc(AMOUNT_DSC_TO_MINT);

        dsc.approve(address(dscEngine), AMOUNT_DSC_TO_MINT);
        dscEngine.burnDsc(AMOUNT_DSC_TO_MINT);

        uint256 userDscBalance = dsc.balanceOf(USER);
        assertEq(userDscBalance, 0);

        (uint256 totalDscMinted,) = dscEngine.getAccountInformation(USER);
        assertEq(totalDscMinted, 0);

        vm.stopPrank();
    }

    ////////////////////////REDEEM COLLATERAL TESTS////////////////////////

    function testRevertsIfRedeemAmountZero() public {
        vm.startPrank(USER);

        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.redeemCollateral(weth, 0);

        vm.stopPrank();
    }

    function testRedeemCollateralFailsIfNotEnoughCollateral() public depositedCollateral {
        vm.startPrank(USER);

        vm.expectRevert();
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL + 1 ether);

        vm.stopPrank();
    }

    function testRedeemCollateralSucceeds() public depositedCollateral {
        vm.startPrank(USER);

        uint256 initialWethBalance = ERC20Mock(weth).balanceOf(USER);

        vm.expectEmit(true, true, true, true, address(dscEngine));
        emit DSCEngine.CollateralRedeemed(USER, USER, weth, AMOUNT_COLLATERAL_TO_REDEEM);
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL_TO_REDEEM);

        uint256 finalWethBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(finalWethBalance, initialWethBalance + AMOUNT_COLLATERAL_TO_REDEEM);

        vm.stopPrank();
    }

    function testRedeemCollateralFailsIfBreaksHealthFactor() public depositedCollateral {
        vm.startPrank(USER);

        dscEngine.mintDsc(AMOUNT_DSC_TO_MINT);

        vm.expectRevert();
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL);

        vm.stopPrank();
    }

    function testCanRedeemAfterBurningAllDsc() public depositedCollateral {
        vm.startPrank(USER);

        dscEngine.mintDsc(AMOUNT_DSC_TO_MINT);

        dsc.approve(address(dscEngine), AMOUNT_DSC_TO_MINT);
        dscEngine.burnDsc(AMOUNT_DSC_TO_MINT);

        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL);

        uint256 finalWethBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(finalWethBalance, STARTING_ERC20_BALANCE);

        uint256 finalDscBalance = dsc.balanceOf(USER);
        assertEq(finalDscBalance, 0);

        vm.stopPrank();
    }

    ////////////////////////REDEEM COLLATERAL FOR DSC TESTS////////////////////////

    function testCanRedeemCollateralForDsc() public depositedCollateral {
        vm.startPrank(USER);

        uint256 initialWethBalance = ERC20Mock(weth).balanceOf(USER);
        uint256 initialDscBalance = dsc.balanceOf(USER);

        dscEngine.mintDsc(AMOUNT_DSC_TO_MINT);

        uint256 redeemAmount = AMOUNT_COLLATERAL / 2;
        uint256 burnAmount = AMOUNT_DSC_TO_MINT / 2;

        dsc.approve(address(dscEngine), burnAmount);
        dscEngine.redeemCollateralForDsc(weth, redeemAmount, burnAmount);

        uint256 finalWethBalance = ERC20Mock(weth).balanceOf(USER);
        uint256 finalDscBalance = dsc.balanceOf(USER);

        assertEq(finalWethBalance, initialWethBalance + redeemAmount);
        assertEq(finalDscBalance, initialDscBalance + burnAmount);

        vm.stopPrank();
    }

    // function testRevertsIfRedeemForDscBreaksHealthFactor() public depositedCollateral {
    //     vm.startPrank(USER);

    //     dscEngine.mintDsc(AMOUNT_DSC_TO_MINT);

    //     uint256 redeemAmount = (AMOUNT_COLLATERAL * 3) / 4; // Try to redeem too much relative to DSC burn
    //     // uint256 redeemAmount = (AMOUNT_DSC_TO_MINT * 3) / 4; // Try to redeem too much relative to DSC burn
    //     uint256 burnAmount = AMOUNT_DSC_TO_MINT / 4;

    //     console2.log("health factor before redemption: ", dscEngine.getHealthFactor(USER));

    //     dsc.approve(address(dscEngine), burnAmount);
    //     vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 0));
    //     dscEngine.redeemCollateralForDsc(weth, redeemAmount, burnAmount);
    //     console2.log("health factor after redemption: ", dscEngine.getHealthFactor(USER));

    //     vm.stopPrank();
    // }

    ////////////////////////LIQUIDATION TESTS////////////////////////

    function testRevertsIfLiquidationNotAllowed() public depositedCollateral {
        vm.startPrank(USER);

        uint256 dscToMint = dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL) * 40 / 100; // 40% - below threshold
        dscEngine.mintDsc(dscToMint);

        vm.stopPrank();

        vm.startPrank(LIQUIDATOR);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorIsNotBroken.selector);
        dscEngine.liquidate(weth, USER, dscToMint);
        vm.stopPrank();
    }

    function testCanLiquidateUserBelowHealthFactor() public depositedCollateral {
        vm.startPrank(USER);

        uint256 collateralValueInUsd = dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL);
        uint256 maxDscToMint = collateralValueInUsd * LIQUIDATION_THRESHOLD / LIQUIDATION_PRECISION;
        dscEngine.mintDsc(maxDscToMint);
        vm.stopPrank();

        // Drop ETH price by 30% to put user underwater
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(int256(2000e8 * 70 / 100));

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        dscEngine.mintDsc(maxDscToMint / 2);
        dsc.approve(address(dscEngine), maxDscToMint);

        uint256 debtToCover = maxDscToMint / 2;
        uint256 liquidatorInitialWethBalance = ERC20Mock(weth).balanceOf(LIQUIDATOR);

        dscEngine.liquidate(weth, USER, debtToCover);

        uint256 liquidatorFinalWethBalance = ERC20Mock(weth).balanceOf(LIQUIDATOR);

        uint256 tokenAmountFromDebtCovered = dscEngine.getTokenAmountFromUsd(weth, debtToCover);
        uint256 liquidationBonus = tokenAmountFromDebtCovered * 10 / 100; // 10% bonus
        uint256 expectedCollateralReceived = tokenAmountFromDebtCovered + liquidationBonus;

        assertGt(liquidatorFinalWethBalance, liquidatorInitialWethBalance);
        assertEq(liquidatorFinalWethBalance, liquidatorInitialWethBalance + expectedCollateralReceived);

        vm.stopPrank();
    }

    //     function testRevertsIfHealthFactorNotImproved() public depositedCollateral {
    //         vm.startPrank(USER);

    //         // Mint maximum allowed
    //         uint256 collateralValueInUsd = dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL);
    //         uint256 maxDscToMint = collateralValueInUsd * LIQUIDATION_THRESHOLD / LIQUIDATION_PRECISION;
    //         dscEngine.mintDsc(maxDscToMint);
    //         vm.stopPrank();

    //         // Drop ETH price by 40% to put user underwater
    //         MockV3Aggregator(wethUsdPriceFeed).updateAnswer(int256(2000e8 * 60 / 100)); // Assume original price was 1000

    //         // Setup liquidator
    //         vm.startPrank(LIQUIDATOR);
    //         ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
    //         dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
    //         dscEngine.mintDsc(0.1 ether); // Mint 1 DSC
    //         dsc.approve(address(dscEngine), 0.1 ether);

    //         // Try to liquidate with a tiny amount, which shouldn't improve health factor enough
    //         uint256 debtToCover = 0.1 ether; // Too small to fix the health factor

    //         vm.expectRevert(DSCEngine.DSCEngine__HealthFactorIsNotImproved.selector);
    //         dscEngine.liquidate(weth, USER, debtToCover);

    //         vm.stopPrank();
    //     }

    // function testLiquidatorHealthFactorRemainsValid() public depositedCollateral {
    //     // Setup user with borderline health factor
    //     vm.startPrank(USER);

    //     uint256 collateralValueInUsd = dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL);
    //     uint256 maxDscToMint = collateralValueInUsd * LIQUIDATION_THRESHOLD / LIQUIDATION_PRECISION;
    //     dscEngine.mintDsc(maxDscToMint);

    //     vm.stopPrank();

    //     // Drop ETH price to make user liquidatable
    //     MockV3Aggregator(wethUsdPriceFeed).updateAnswer(int256(2000e8 * 70 / 100));

    //     // Setup liquidator with just enough collateral
    //     vm.startPrank(LIQUIDATOR);
    //     ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
    //     dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);

    //     // Mint almost maximum DSC (close to liquidation)
    //     uint256 liquidatorCollateralValueInUsd = dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL);
    //     uint256 liquidatorMaxDscToMint = liquidatorCollateralValueInUsd * LIQUIDATION_THRESHOLD / LIQUIDATION_PRECISION;
    //     uint256 liquidatorDscToMint = (liquidatorMaxDscToMint * 90) / 100; // 90% of max
    //     dscEngine.mintDsc(liquidatorDscToMint);

    //     dsc.approve(address(dscEngine), liquidatorDscToMint);

    //     // Attempt to liquidate with an amount that would break the liquidator's health factor
    //     uint256 debtToCover = liquidatorDscToMint;

    //     vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 0));
    //     dscEngine.liquidate(weth, USER, debtToCover);

    //     vm.stopPrank();
    // }
}
