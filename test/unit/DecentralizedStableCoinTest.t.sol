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

    function testDecentralizedStableCoinIsInitializedCorrectly() public view{
        //check name and symbol
        assertEq(stableCoin.name(), "DecentralizedStableCoin");
        assertEq(stableCoin.symbol(), "DSC");

        //check owner
        assertEq(stableCoin.owner(), owner);
    }

    function testDecentralizedStableCoinMintsProperly() public {
        uint256 amount = 100;

        //mint token
        vm.prank(owner);
        stableCoin.mint(user, amount);

        //check balance of user
        assertEq(stableCoin.balanceOf(user), amount);

        //check total supply
        assertEq(stableCoin.totalSupply(), amount);
    }

    function testDecentralizedStableCoinFailsToMintWithAddressZero() public {
        uint256 amount = 100;

        //mint token
        vm.prank(owner);
        vm.expectRevert();
        stableCoin.mint(address(0), amount);
    }

    function testDecentralizedStableCoinFailsToMintWithZeroAmount() public {
        uint256 amount = 0;

        //mint token
        vm.prank(owner);
        vm.expectRevert();
        stableCoin.mint(user, amount);
    }

    function testDecentralizedStableCoinBurnsTokenProperly() public {
        uint256 mintAmount = 100;
        uint256 burnAmount = 50;

        //mint token
        vm.prank(owner);
        stableCoin.mint(owner, mintAmount);

        //burn token
        vm.prank(owner);
        stableCoin.burn(burnAmount);

        //check balance of owner
        assertEq(stableCoin.balanceOf(owner), mintAmount - burnAmount);

        //check total supply
        assertEq(stableCoin.totalSupply(), mintAmount - burnAmount);
    }

    function testDecentralizedStableCoinFailsWhenBurnAmountExceedsBalance() public {
        uint256 mintAmount = 100;
        uint256 burnAmount = 200;

        //mint token
        vm.prank(owner);
        stableCoin.mint(owner, mintAmount); 

        //burn token
        vm.prank(owner);
        vm.expectRevert();
        stableCoin.burn(burnAmount);
    }

    function testDecentralizedStableCointFailsWhenBurnAmountIsZero() public {
        uint256 mintAmount = 100;
        uint256 burnAmount = 0;

        //mint token
        vm.prank(owner);
        stableCoin.mint(owner, mintAmount);

        //burn token
        vm.prank(owner);
        vm.expectRevert();
        stableCoin.burn(burnAmount);
    }

    function testDecentralizedStableCoinDoesNotAllowNonOwnerMinting() public {
        uint256 amount = 100;   

        //mint token
        vm.prank(user);
        vm.expectRevert();
        stableCoin.mint(user, amount);
    }

    function testDecentralizedStableCoinDoesNotAllowNonOwnerBurning() public {
        uint256 amount = 100;

        //mint token
        vm.prank(owner);
        stableCoin.mint(owner, amount); 

        //burn token    
        vm.prank(user);
        vm.expectRevert();
        stableCoin.burn(amount);
    }
}
