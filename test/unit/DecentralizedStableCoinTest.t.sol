//SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";

contract DecentralizedStableCoinTest is Test {
    DecentralizedStableCoin stableCoin;

    address owner = makeAddr("owner");
    address user = makeAddr("user");

    function setUp() public {
        vm.prank(owner);
        stableCoin = new DecentralizedStableCoin();
    }

    function testDecentralizedStableCoinIsInitializedCorrectly() public view {
        assertEq(stableCoin.name(), "DecentralizedStableCoin");
        assertEq(stableCoin.symbol(), "DSC");

        assertEq(stableCoin.owner(), owner);
    }

    function testDecentralizedStableCoinMintsProperly() public {
        uint256 amount = 100;

        vm.prank(owner);
        stableCoin.mint(user, amount);

        assertEq(stableCoin.balanceOf(user), amount);

        assertEq(stableCoin.totalSupply(), amount);
    }

    function testDecentralizedStableCoinFailsToMintWithAddressZero() public {
        uint256 amount = 100;

        vm.prank(owner);
        vm.expectRevert();
        stableCoin.mint(address(0), amount);
    }

    function testDecentralizedStableCoinFailsToMintWithZeroAmount() public {
        uint256 amount = 0;

        vm.prank(owner);
        vm.expectRevert();
        stableCoin.mint(user, amount);
    }

    function testDecentralizedStableCoinBurnsTokenProperly() public {
        uint256 mintAmount = 100;
        uint256 burnAmount = 50;

        vm.prank(owner);
        stableCoin.mint(owner, mintAmount);

        vm.prank(owner);
        stableCoin.burn(burnAmount);

        assertEq(stableCoin.balanceOf(owner), mintAmount - burnAmount);

        assertEq(stableCoin.totalSupply(), mintAmount - burnAmount);
    }

    function testDecentralizedStableCoinFailsWhenBurnAmountExceedsBalance() public {
        uint256 mintAmount = 100;
        uint256 burnAmount = 200;

        vm.prank(owner);
        stableCoin.mint(owner, mintAmount);

        vm.prank(owner);
        vm.expectRevert();
        stableCoin.burn(burnAmount);
    }

    function testDecentralizedStableCointFailsWhenBurnAmountIsZero() public {
        uint256 mintAmount = 100;
        uint256 burnAmount = 0;

        vm.prank(owner);
        stableCoin.mint(owner, mintAmount);

        vm.prank(owner);
        vm.expectRevert();
        stableCoin.burn(burnAmount);
    }

    function testDecentralizedStableCoinDoesNotAllowNonOwnerMinting() public {
        uint256 amount = 100;

        vm.prank(user);
        vm.expectRevert();
        stableCoin.mint(user, amount);
    }

    function testDecentralizedStableCoinDoesNotAllowNonOwnerBurning() public {
        uint256 amount = 100;

        vm.prank(owner);
        stableCoin.mint(owner, amount);

        vm.prank(user);
        vm.expectRevert();
        stableCoin.burn(amount);
    }
}
