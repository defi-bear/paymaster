// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {MessageHashUtils} from "openzeppelin-contracts-v5.0.0/contracts/utils/cryptography/MessageHashUtils.sol";
import {ERC20} from "openzeppelin-contracts-v5.0.0/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin-v4.8.0/contracts/utils/cryptography/ECDSA.sol";

import {UserOperation} from "account-abstraction-v6/interfaces/UserOperation.sol";
import {IEntryPoint} from "account-abstraction-v7/interfaces/IEntryPoint.sol";

import {PostOpMode} from "../src/interfaces/PostOpMode.sol";
import {BaseSingletonPaymaster} from "../src/base/BaseSingletonPaymaster.sol";
import {SingletonPaymaster} from "../src/SingletonPaymaster.sol";

import {EntryPoint} from "./utils/account-abstraction/v06/core/EntryPoint.sol";
import {TestERC20} from "./utils/TestERC20.sol";
import {TestCounter} from "./utils/TestCounter.sol";
import {SimpleAccountFactory, SimpleAccount} from "./utils/account-abstraction/v06/samples/SimpleAccountFactory.sol";

using ECDSA for bytes32;

struct SignatureData {
    uint8 v;
    bytes32 r;
    bytes32 s;
}

struct PaymasterData {
    address paymasterAddress;
    uint128 preVerificationGas;
    uint128 postOpGas;
    uint8 mode;
    uint128 fundAmount;
    uint48 validUntil;
    uint48 validAfter;
}

contract SingletonPaymasterV6Test is Test {
    // helpers
    uint8 immutable VERIFYING_MODE = 0;
    uint8 immutable ERC20_MODE = 1;

    address payable beneficiary;
    address paymasterOwner;
    uint256 paymasterOwnerKey;
    address user;
    uint256 userKey;

    SingletonPaymaster paymaster;
    SimpleAccountFactory accountFactory;
    SimpleAccount account;
    EntryPoint entryPoint;

    TestERC20 token;
    TestCounter counter;

    function setUp() external {
        token = new TestERC20(18);
        counter = new TestCounter();

        beneficiary = payable(makeAddr("beneficiary"));
        (paymasterOwner, paymasterOwnerKey) = makeAddrAndKey("paymasterOperator");
        (user, userKey) = makeAddrAndKey("user");

        entryPoint = new EntryPoint();
        accountFactory = new SimpleAccountFactory(entryPoint);
        account = accountFactory.createAccount(user, 0);

        address[] memory entryPoints = new address[](2);
        entryPoints[0] = address(entryPoint);
        entryPoints[1] = address(1);
        paymaster = new SingletonPaymaster(entryPoints, paymasterOwner);
        paymaster.deposit{value: 100e18}(address(entryPoint));
    }

    function testSuccess(uint8 _mode) external {
        (bool success, bytes memory returnData) =
            address(entryPoint).call(abi.encodeWithSignature("balanceOf(address)", address(paymaster)));
        console2.log(success);
        console2.logBytes(returnData);
        uint8 mode = uint8(bound(_mode, 0, 1));
        setupERC20();

        UserOperation memory op = fillUserOp();

        op.paymasterAndData = getSignedPaymasterData(mode, 0, op);
        op.signature = signUserOp(op, userKey);
        submitUserOp(op);
    }

    function testSuccessLegacy(uint8 _mode) external {
        (bool success, bytes memory returnData) =
            address(entryPoint).call(abi.encodeWithSignature("balanceOf(address)", address(paymaster)));
        console2.log(success);
        console2.logBytes(returnData);
        uint8 mode = uint8(bound(_mode, 0, 1));
        setupERC20();

        UserOperation memory op = fillUserOp();

        op.maxPriorityFeePerGas = 5;
        op.maxFeePerGas = 5;
        op.paymasterAndData = getSignedPaymasterData(mode, 0, op);
        op.signature = signUserOp(op, userKey);
        submitUserOp(op);
    }

    function test_RevertWhen_PaymasterModeInvalid() external {
        setupERC20();

        UserOperation memory op = fillUserOp();

        op.paymasterAndData = abi.encodePacked(address(paymaster), uint128(100000), uint128(50000), uint8(42));
        op.signature = signUserOp(op, userKey);
        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA33 reverted (or OOG)"));
        submitUserOp(op);
    }

    function test_RevertWhen_PaymasterConfigLengthInvalid(uint8 _mode, bytes calldata _randomBytes) external {
        uint8 mode = uint8(bound(_mode, 0, 1));
        setupERC20();

        if (mode == VERIFYING_MODE) {
            vm.assume(_randomBytes.length < 12);
        }

        if (mode == ERC20_MODE) {
            vm.assume(_randomBytes.length < 64);
        }

        UserOperation memory op = fillUserOp();

        op.paymasterAndData = abi.encodePacked(address(paymaster), uint128(100000), uint128(50000), mode, _randomBytes);
        op.signature = signUserOp(op, userKey);
        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, uint256(0), "AA33 reverted (or OOG)"));
        submitUserOp(op);
    }

    function test_RevertWhen_PaymasterSignatureLengthInvalid(uint8 _mode) external {
        uint8 mode = uint8(bound(_mode, 0, 1));
        setupERC20();

        UserOperation memory op = fillUserOp();

        if (mode == VERIFYING_MODE) {
            op.paymasterAndData = abi.encodePacked(
                address(paymaster),
                uint128(100000),
                uint128(50000),
                mode,
                uint48(0),
                int48(0),
                "BYTES WITH INVALID SIGNATURE LENGTH"
            );
        }
        if (mode == ERC20_MODE) {
            op.paymasterAndData = abi.encodePacked(
                address(paymaster),
                uint128(100000),
                uint128(50000),
                mode,
                uint48(0),
                int48(0),
                address(token),
                uint256(1),
                "BYTES WITH INVALID SIGNATURE LENGTH"
            );
        }

        op.signature = signUserOp(op, userKey);
        vm.expectRevert(
            abi.encodeWithSelector(IEntryPoint.FailedOp.selector, uint256(0), string("AA33 reverted (or OOG)"))
        );
        submitUserOp(op);
    }

    // ERC20 mode specific errors

    function test_RevertWhen_UnauthorizedAttemptTransfer() external {
        vm.expectRevert();
        paymaster.attemptTransfer(address(1), address(2), address(3), 4);
    }

    function test_PostOpTransferFromFailed() external {
        UserOperation memory op = fillUserOp();

        op.paymasterAndData = getSignedPaymasterData(1, 0, op);

        op.signature = signUserOp(op, userKey);
        submitUserOp(op);
    }

    function test_RevertWhen_TokenAddressInvalid() external {
        setupERC20();

        UserOperation memory op = fillUserOp();

        op.paymasterAndData = abi.encodePacked(
            address(paymaster),
            uint128(100000),
            uint128(50000),
            ERC20_MODE,
            uint48(0),
            int48(0),
            address(0), // will throw here, token address cannot be zero.
            uint256(1),
            "DummySignature"
        );

        op.signature = signUserOp(op, userKey);
        vm.expectRevert(
            abi.encodeWithSelector(IEntryPoint.FailedOp.selector, uint256(0), string("AA33 reverted (or OOG)"))
        );
        submitUserOp(op);
    }

    function test_RevertWhen_ExchangeRateInvalid() external {
        setupERC20();

        UserOperation memory op = fillUserOp();

        op.paymasterAndData = abi.encodePacked(
            address(paymaster),
            uint128(100000),
            uint128(50000),
            ERC20_MODE,
            uint48(0),
            int48(0),
            address(token),
            uint256(0), // will throw here, price cannot be zero.
            "DummySignature"
        );

        op.signature = signUserOp(op, userKey);
        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, uint256(0), "AA33 reverted (or OOG)"));
        submitUserOp(op);
    }

    function test_RevertWhen_PaymasterAndDataLengthInvalid() external {
        setupERC20();

        UserOperation memory op = fillUserOp();

        op.paymasterAndData = abi.encodePacked(address(paymaster), uint128(100000), uint128(50000));

        op.signature = signUserOp(op, userKey);
        vm.expectRevert();
        submitUserOp(op);
    }

    function test_RevertWhen_NonEntryPointCaller() external {
        vm.expectRevert("Sender not EntryPoint");
        paymaster.postOp(
            PostOpMode.opSucceeded,
            abi.encodePacked(address(account), address(token), uint256(5), bytes32(0), uint256(0), uint256(0)),
            0
        );
    }

    // HELPERS //

    function getSignedPaymasterData(uint8 mode, uint128 fundAmount, UserOperation memory userOp)
        private
        view
        returns (bytes memory)
    {
        PaymasterData memory data = PaymasterData({
            paymasterAddress: address(paymaster),
            preVerificationGas: 250000,
            postOpGas: 150000,
            mode: mode,
            fundAmount: fundAmount,
            validUntil: 0,
            validAfter: 0
        });

        if (mode == VERIFYING_MODE) {
            return getVerifyingModeData(data, userOp);
        } else if (mode == ERC20_MODE) {
            return getERC20ModeData(data, userOp);
        }

        revert("unexpected mode");
    }

    function getVerifyingModeData(PaymasterData memory data, UserOperation memory userOp)
        private
        view
        returns (bytes memory)
    {
        bytes32 hash = paymaster.getHash(userOp, data.validUntil, data.validAfter, address(0), 0, data.fundAmount);
        SignatureData memory sig = getSignature(hash);

        return abi.encodePacked(
            data.paymasterAddress,
            data.preVerificationGas,
            data.postOpGas,
            data.mode,
            data.fundAmount,
            data.validUntil,
            data.validAfter,
            abi.encodePacked(sig.r, sig.s, sig.v)
        );
    }

    function getERC20ModeData(PaymasterData memory data, UserOperation memory userOp)
        private
        view
        returns (bytes memory)
    {
        uint256 price = 0.0016 * 1e18;
        address erc20 = address(token);
        bytes32 hash = paymaster.getHash(userOp, data.validUntil, data.validAfter, erc20, price, data.fundAmount);
        SignatureData memory sig = getSignature(hash);

        return abi.encodePacked(
            data.paymasterAddress,
            data.preVerificationGas,
            data.postOpGas,
            data.mode,
            data.fundAmount,
            data.validUntil,
            data.validAfter,
            erc20,
            price,
            abi.encodePacked(sig.r, sig.s, sig.v)
        );
    }

    function getSignature(bytes32 hash) private view returns (SignatureData memory) {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(hash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(paymasterOwnerKey, digest);
        return SignatureData(v, r, s);
    }

    function fillUserOp() public view returns (UserOperation memory op) {
        op.sender = address(account);
        op.nonce = entryPoint.getNonce(address(account), 0);
        op.callData = abi.encodeWithSelector(
            SimpleAccount.execute.selector, address(counter), 0, abi.encodeWithSelector(TestCounter.count.selector)
        );
        op.callGasLimit = 50000;
        op.verificationGasLimit = 180000;
        op.preVerificationGas = 50000;
        op.maxFeePerGas = 50;
        op.maxPriorityFeePerGas = 15;
        op.signature = signUserOp(op, userKey);
        return op;
    }

    function signUserOp(UserOperation memory op, uint256 _key) public view returns (bytes memory signature) {
        bytes32 hash = entryPoint.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_key, hash.toEthSignedMessageHash());
        signature = abi.encodePacked(r, s, v);
    }

    function submitUserOp(UserOperation memory op) private {
        UserOperation[] memory ops = new UserOperation[](1);
        ops[0] = op;
        entryPoint.handleOps(ops, beneficiary);
    }

    function setupERC20() private {
        token.sudoMint(address(account), 1000e18); // 1000 usdc;
        token.sudoMint(address(paymaster), 1); // 1000 usdc;
        token.sudoApprove(address(account), address(paymaster), UINT256_MAX);
    }
}
