//SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../../test/mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;

    ERC20Mock weth;
    ERC20Mock wbtc;

    uint256 public timesMintDscCalled;
    address[] usersWithCollateralDeposited;

    MockV3Aggregator public wethUsdPriceFeed;

    uint256 constant MAX_DEPOSIT_AMOUNT = type(uint96).max;

    constructor(DecentralizedStableCoin _dsc, DSCEngine _dscEngine) {
        dsc = _dsc;
        dscEngine = _dscEngine;

        address[] memory collateralTokens = dscEngine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        wethUsdPriceFeed = MockV3Aggregator(dscEngine.getCollateralTokenPriceFeed(address(weth)));
    }

    function depositCollateral(uint256 collateralSeed, uint256 collateralAmount) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        collateralAmount = bound(collateralAmount, 1, MAX_DEPOSIT_AMOUNT);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, collateralAmount);
        collateral.approve(address(dscEngine), collateralAmount);
        dscEngine.depositCollateral(address(collateral), collateralAmount);
        vm.stopPrank();
        usersWithCollateralDeposited.push(msg.sender);
    }

    function mintDsc(uint256 amountDscToMint, uint256 userSeed) public {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }

        address user = usersWithCollateralDeposited[userSeed % usersWithCollateralDeposited.length];

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(user);

        int256 maxDscToMint = (int256(collateralValueInUsd) / 2) - int256(totalDscMinted);
        if (maxDscToMint < 0) {
            return;
        }

        amountDscToMint = bound(amountDscToMint, 0, uint256(maxDscToMint));
        if (amountDscToMint == 0) {
            return;
        }

        vm.startPrank(user);
        dscEngine.mintDsc(amountDscToMint);
        vm.stopPrank();
    }

    function redeemCollateral(uint256 collateralSeed, uint256 collateralAmount) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        uint256 maxCollateralToRedeem = dscEngine.getCollateralBalanceOfUser(msg.sender, address(collateral));

        if (maxCollateralToRedeem == 0) {
            return;
        }
        collateralAmount = bound(collateralAmount, 1, maxCollateralToRedeem);

        vm.startPrank(msg.sender);
        dscEngine.redeemCollateral(address(collateral), collateralAmount);
        vm.stopPrank();
    }

    //////////////////////////////////////HELPER FUNCTIONS//////////////////////////////////////

    function _getCollateralFromSeed(uint256 collateralSeed) public view returns (ERC20Mock collateral) {
        if ((collateralSeed % 2) == 0) {
            return weth;
        }

        return wbtc;
    }
}
