//SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

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
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 20 ether;
    uint256 public constant AMOUNT_DSC_TO_MINT = 4 ether;
    uint256 public constant AMOUNT_DSC_TO_BURN = 4 ether;
    uint256 public constant AMOUNT_COLLATERAL_TO_REDEEM = 0.5 ether;
    uint256 public constant AMOUNT_COLLATERAL_TO_BREAK_HEALTH_FACTOR = 11 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dscEngine, config) = deployer.run();
        (wethUsdPriceFeed, wbtcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(USER, STARTING_ERC20_BALANCE);

    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    ////////////////////////INTEGRATION TESTS////////////////////////

    function testRedeemCollateralForDscSucceedsWithValidAmounts() public depositedCollateral {
        vm.startPrank(USER);

        dscEngine.mintDsc(AMOUNT_DSC_TO_MINT);

        uint256 initialWethBalance = ERC20Mock(weth).balanceOf(USER);
        uint256 initialDscBalance = dsc.balanceOf(USER);

        dsc.approve(address(dscEngine), AMOUNT_DSC_TO_BURN);

        dscEngine.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL_TO_REDEEM, AMOUNT_DSC_TO_BURN);

        uint256 finalWethBalance = ERC20Mock(weth).balanceOf(USER);
        uint256 finalDscBalance = dsc.balanceOf(USER);

        assertEq(finalWethBalance, initialWethBalance + AMOUNT_COLLATERAL_TO_REDEEM);
        assertEq(finalDscBalance, initialDscBalance - AMOUNT_DSC_TO_BURN);

        vm.stopPrank();
    }

    function testRedeemCollateralForDscFailsWithInsufficientDscBalance() public depositedCollateral {
        vm.startPrank(USER);

        dscEngine.mintDsc(AMOUNT_DSC_TO_MINT / 2);

        dsc.approve(address(dscEngine), AMOUNT_DSC_TO_BURN);

        vm.expectRevert();
        dscEngine.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL_TO_REDEEM, AMOUNT_DSC_TO_BURN);

        vm.stopPrank();
    }

    function testRedeemCollateralForDscFailsWithInsufficientAllowance() public depositedCollateral {
        vm.startPrank(USER);

        dscEngine.mintDsc(AMOUNT_DSC_TO_MINT);

        vm.expectRevert();
        dscEngine.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL_TO_REDEEM, AMOUNT_DSC_TO_BURN);

        vm.stopPrank();
    }

    function testRedeemCollateralForDscFailsIfBreaksHealthFactor() public depositedCollateral {
        vm.startPrank(USER);

        dscEngine.mintDsc(AMOUNT_DSC_TO_MINT);

        dsc.approve(address(dscEngine), AMOUNT_DSC_TO_BURN);

        vm.expectRevert();
        dscEngine.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, AMOUNT_DSC_TO_BURN - 3 ether);

        vm.stopPrank();
    }

    function testRedeemCollateralForDscWorksWithMultipleTokenTypes() public {
        vm.startPrank(USER);

        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        ERC20Mock(wbtc).approve(address(dscEngine), AMOUNT_COLLATERAL);
        
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(wbtc, AMOUNT_COLLATERAL);
        
        dscEngine.mintDsc(AMOUNT_DSC_TO_MINT * 2); 

        uint256 initialWethBalance = ERC20Mock(weth).balanceOf(USER);
        uint256 initialWbtcBalance = ERC20Mock(wbtc).balanceOf(USER);
        uint256 initialDscBalance = dsc.balanceOf(USER);

        dsc.approve(address(dscEngine), AMOUNT_DSC_TO_BURN);

        dscEngine.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL_TO_REDEEM, AMOUNT_DSC_TO_BURN);
        
        dsc.approve(address(dscEngine), AMOUNT_DSC_TO_BURN);

        dscEngine.redeemCollateralForDsc(wbtc, AMOUNT_COLLATERAL_TO_REDEEM, AMOUNT_DSC_TO_BURN);

        uint256 finalWethBalance = ERC20Mock(weth).balanceOf(USER);
        uint256 finalWbtcBalance = ERC20Mock(wbtc).balanceOf(USER);
        uint256 finalDscBalance = dsc.balanceOf(USER);

        assertEq(finalWethBalance, initialWethBalance + AMOUNT_COLLATERAL_TO_REDEEM);
        assertEq(finalWbtcBalance, initialWbtcBalance + AMOUNT_COLLATERAL_TO_REDEEM);
        assertEq(finalDscBalance, initialDscBalance - (AMOUNT_DSC_TO_BURN * 2));
        
        vm.stopPrank();
    }

    
}
