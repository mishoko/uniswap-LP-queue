// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

/// SPIKE: can a PLAIN (non-Safe) contract place a real CoW Protocol conditional order?
///
/// Everything here runs against the REAL deployed CoW contracts on a Sepolia fork.
/// Nothing is mocked. Interfaces are re-declared locally so we do not pull the GPL
/// composable-cow / cowprotocol dependency trees into this repo.

// ---------------------------------------------------------------- CoW types

library GPv2Order {
    struct Data {
        address sellToken;
        address buyToken;
        address receiver;
        uint256 sellAmount;
        uint256 buyAmount;
        uint32 validTo;
        bytes32 appData;
        uint256 feeAmount;
        bytes32 kind;
        bool partiallyFillable;
        bytes32 sellTokenBalance;
        bytes32 buyTokenBalance;
    }

    bytes32 internal constant TYPE_HASH = hex"d5a25ba2e97094ad7d83dc28a6572da797d6b3e7fc6663bd93efb789fc17e489";
    bytes32 internal constant KIND_SELL = hex"f3b277728b3fee749481eb3e0b3b48980dbbab78658fc419025cb16eee346775";
    bytes32 internal constant BALANCE_ERC20 = hex"5a28e9363bb942b639270062aa6bb295f434bcdfc42c97267bf003f272060dc9";

    function hash(Data memory order, bytes32 domainSeparator) internal pure returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(TYPE_HASH, order));
        return keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));
    }
}

interface IConditionalOrder {
    struct ConditionalOrderParams {
        address handler;
        bytes32 salt;
        bytes staticInput;
    }
}

interface IComposableCoW {
    struct PayloadStruct {
        bytes32[] proof;
        IConditionalOrder.ConditionalOrderParams params;
        bytes offchainInput;
    }

    function create(IConditionalOrder.ConditionalOrderParams calldata params, bool dispatch) external;
    function singleOrders(address owner, bytes32 h) external view returns (bool);
    function hash(IConditionalOrder.ConditionalOrderParams memory params) external pure returns (bytes32);
    function domainSeparator() external view returns (bytes32);
    function getTradeableOrderWithSignature(
        address owner,
        IConditionalOrder.ConditionalOrderParams calldata params,
        bytes calldata offchainInput,
        bytes32[] calldata proof
    ) external view returns (GPv2Order.Data memory order, bytes memory signature);
}

library GPv2Trade {
    struct Data {
        uint256 sellTokenIndex;
        uint256 buyTokenIndex;
        address receiver;
        uint256 sellAmount;
        uint256 buyAmount;
        uint32 validTo;
        bytes32 appData;
        uint256 feeAmount;
        uint256 flags;
        uint256 executedAmount;
        bytes signature;
    }
}

library GPv2Interaction {
    struct Data {
        address target;
        uint256 value;
        bytes callData;
    }
}

interface IGPv2Settlement {
    function domainSeparator() external view returns (bytes32);
    function vaultRelayer() external view returns (address);
    function authenticator() external view returns (address);
    function settle(
        address[] calldata tokens,
        uint256[] calldata clearingPrices,
        GPv2Trade.Data[] calldata trades,
        GPv2Interaction.Data[][3] calldata interactions
    ) external;
}

interface IAllowListAdmin {
    function addSolver(address solver) external;
}

contract TestToken {
    string public name = "T";
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public decimals = 18;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        balanceOf[f] -= a; balanceOf[t] += a; return true;
    }
}

interface IAllowList {
    function isSolver(address prospectiveSolver) external view returns (bool);
    function manager() external view returns (address);
}

// ------------------------------------------------- the handler (plain, non-Safe)

/// @dev Mirrors `BaseConditionalOrder`: an order generator. NOT a Safe, no Safe libs.
contract SluiceHandler {
    error OrderNotValid(string);

    // type(IConditionalOrderGenerator).interfaceId, as computed by ComposableCoW.
    // IConditionalOrderGenerator = IConditionalOrder(verify) ^ IERC165 ^ getTradeableOrder.
    bytes4 constant CONDITIONAL_ORDER_GENERATOR_ID = 0xb8296fc4;
    bytes4 constant ERC165_ID = 0x01ffc9a7;

    struct Static {
        address sellToken;
        address buyToken;
        uint256 sellAmount;
        uint256 buyAmount;
        uint32 validTo;
    }

    function getTradeableOrder(address owner, address, bytes32, bytes calldata staticInput, bytes calldata)
        public
        pure
        returns (GPv2Order.Data memory)
    {
        Static memory s = abi.decode(staticInput, (Static));
        return GPv2Order.Data({
            sellToken: s.sellToken,
            buyToken: s.buyToken,
            receiver: owner, // hook receives, so it can split limit vs surplus
            sellAmount: s.sellAmount,
            buyAmount: s.buyAmount,
            validTo: s.validTo,
            appData: bytes32(0),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
    }

    function verify(
        address owner,
        address sender,
        bytes32 _hash,
        bytes32 domainSeparator,
        bytes32 ctx,
        bytes calldata staticInput,
        bytes calldata offchainInput,
        GPv2Order.Data calldata
    ) external pure {
        GPv2Order.Data memory generated = getTradeableOrder(owner, sender, ctx, staticInput, offchainInput);
        if (_hash != GPv2Order.hash(generated, domainSeparator)) revert OrderNotValid("invalid hash");
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == CONDITIONAL_ORDER_GENERATOR_ID || id == ERC165_ID;
    }
}

// -------------------------------------------- the "hook" (plain, non-Safe owner)

/// @dev Stands in for the Sluice hook. A plain contract. No Safe, no fallback handler.
contract PlainOwnerHook {
    IComposableCoW immutable ccow;
    bytes32 immutable cowDomainSeparator;

    bytes4 constant ERC1271_MAGIC = 0x1626ba7e;

    error BadOrderHash();
    error NotAuthed();

    bool public sabotage; // MUTATION SWITCH: return a wrong magic value
    function setSabotage(bool v) external { sabotage = v; }

    constructor(IComposableCoW _ccow, bytes32 _ds) {
        ccow = _ccow;
        cowDomainSeparator = _ds;
    }

    function createOrder(IConditionalOrder.ConditionalOrderParams calldata params) external {
        ccow.create(params, true);
    }

    function approveToken(address token, address spender, uint256 amount) external {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        require(ok, "approve failed");
    }

    /// @notice The ENTIRE non-Safe integration surface. This is what a hook must implement.
    function isValidSignature(bytes32 _hash, bytes calldata signature) external view returns (bytes4) {
        (GPv2Order.Data memory order, IComposableCoW.PayloadStruct memory payload) =
            abi.decode(signature, (GPv2Order.Data, IComposableCoW.PayloadStruct));

        // 1. the conditional order must have been authorised by THIS contract
        bytes32 ctx = ccow.hash(payload.params);
        if (!ccow.singleOrders(address(this), ctx)) revert NotAuthed();

        // 2. the presented digest must be the digest of the presented order
        if (_hash != GPv2Order.hash(order, cowDomainSeparator)) revert BadOrderHash();

        // 3. the handler must agree the order is currently valid
        SluiceHandler(payload.params.handler).verify(
            address(this), msg.sender, _hash, cowDomainSeparator, ctx, payload.params.staticInput, payload.offchainInput, order
        );

        return sabotage ? bytes4(0xdeadbeef) : ERC1271_MAGIC;
    }
}

/// @dev Identical, but ALSO implements ERC165 returning false for unknown ids -- the footgun.
contract PlainOwnerHookWithERC165 is PlainOwnerHook {
    constructor(IComposableCoW _c, bytes32 _d) PlainOwnerHook(_c, _d) {}

    function supportsInterface(bytes4) external pure returns (bool) {
        return false; // <-- returns false rather than reverting
    }
}

// ------------------------------------------------------------------- the test

contract CowNonSafeForkTest is Test {
    IComposableCoW constant CCOW = IComposableCoW(0xfdaFc9d1902f4e0b84f65F49f244b32b31013b74);
    IGPv2Settlement constant SETTLEMENT = IGPv2Settlement(0x9008D19f58AAbD9eD0D60971565AA8510560ab41);
    IAllowList constant ALLOWLIST = IAllowList(0x2c4c28DDBdAc9C5E7055b4C863b72eA0149D8aFE);

    PlainOwnerHook hook;
    SluiceHandler handler;
    bytes32 ds;

    function setUp() public {
        vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));
        ds = SETTLEMENT.domainSeparator();
        handler = new SluiceHandler();
        hook = new PlainOwnerHook(CCOW, ds);
    }

    function _params() internal view returns (IConditionalOrder.ConditionalOrderParams memory) {
        SluiceHandler.Static memory s = SluiceHandler.Static({
            sellToken: 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14, // WETH sepolia
            buyToken: 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238, // USDC sepolia
            sellAmount: 1 ether,
            buyAmount: 1000e6,
            validTo: uint32(block.timestamp + 1 hours)
        });
        return IConditionalOrder.ConditionalOrderParams({
            handler: address(handler),
            salt: keccak256("sluice-spike"),
            staticInput: abi.encode(s)
        });
    }

    /// STEP 0: sanity -- ComposableCoW's own domain separator matches the settlement contract's.
    function test_0_realContractsArePresent() public view {
        assertGt(address(CCOW).code.length, 0, "ComposableCoW has no code");
        assertGt(address(SETTLEMENT).code.length, 0, "GPv2Settlement has no code");
        assertEq(CCOW.domainSeparator(), ds, "domain separators disagree");
        console2.log("CoW domainSeparator:");
        console2.logBytes32(ds);
    }

    /// STEP 1+2: a PLAIN contract calls create() and the storage write lands.
    function test_1_plainContractCanCreateConditionalOrder() public {
        IConditionalOrder.ConditionalOrderParams memory p = _params();
        bytes32 h = CCOW.hash(p);

        assertFalse(CCOW.singleOrders(address(hook), h), "should start unauthed");
        hook.createOrder(p);
        assertTrue(CCOW.singleOrders(address(hook), h), "STORAGE WRITE DID NOT LAND");
        console2.log("create() succeeded from a plain non-Safe contract. owner:", address(hook));
    }

    /// STEP 3: the watch-tower path. This is the one that could have been Safe-gated.
    function test_2_watchTowerCanDeriveOrderAndSignature() public {
        IConditionalOrder.ConditionalOrderParams memory p = _params();
        hook.createOrder(p);

        (GPv2Order.Data memory order, bytes memory sig) =
            CCOW.getTradeableOrderWithSignature(address(hook), p, bytes(""), new bytes32[](0));

        assertEq(order.sellAmount, 1 ether, "order malformed");
        assertEq(order.receiver, address(hook), "receiver should be the hook");
        assertGt(sig.length, 0, "no signature produced");
        console2.log("watch-tower produced a signature of length", sig.length);

        // the EIP-1271-forwarder branch encodes (order, payload); the Safe branch would
        // have encoded a safeSignature(...) call. Prove we are on the forwarder branch.
        (GPv2Order.Data memory decoded,) = abi.decode(sig, (GPv2Order.Data, IComposableCoW.PayloadStruct));
        assertEq(decoded.sellAmount, order.sellAmount, "not the EIP-1271 forwarder encoding");
        // and prove it is NOT the Safe branch: that branch prefixes safeSignature(bytes32,bytes32,bytes,bytes)
        bytes4 safeSigSelector = bytes4(keccak256("safeSignature(bytes32,bytes32,bytes,bytes)"));
        bytes4 first4 = bytes4(sig[0]) | (bytes4(sig[1]) >> 8) | (bytes4(sig[2]) >> 16) | (bytes4(sig[3]) >> 24);
        assertTrue(first4 != safeSigSelector, "took the SAFE branch, not the forwarder branch");
        console2.log("-> took the EIP-1271 Forwarder branch (non-Safe). CONFIRMED.");
    }

    /// STEP 4: the settlement check itself -- exactly what GPv2Settlement does for an
    /// EIP-1271 order: call owner.isValidSignature(digest, sig) and require the magic value.
    function test_3_settlementSignatureCheckAcceptsPlainContract() public {
        IConditionalOrder.ConditionalOrderParams memory p = _params();
        hook.createOrder(p);
        (GPv2Order.Data memory order, bytes memory sig) =
            CCOW.getTradeableOrderWithSignature(address(hook), p, bytes(""), new bytes32[](0));

        bytes32 digest = GPv2Order.hash(order, ds);
        bytes4 magic = hook.isValidSignature(digest, sig);
        assertEq(magic, bytes4(0x1626ba7e), "GPv2Settlement would REJECT this order");
        console2.log("ERC-1271 magic value returned. Settlement would accept.");
    }

    /// THE FOOTGUN: a hook that implements ERC165 and returns false is BRICKED.
    function test_4_erc165ReturningFalseBricksTheWatchTower() public {
        PlainOwnerHookWithERC165 bad = new PlainOwnerHookWithERC165(CCOW, ds);
        IConditionalOrder.ConditionalOrderParams memory p = _params();
        vm.prank(address(bad));
        CCOW.create(p, true);

        vm.expectRevert(bytes4(keccak256("InvalidFallbackHandler()")));
        CCOW.getTradeableOrderWithSignature(address(bad), p, bytes(""), new bytes32[](0));
        console2.log("CONFIRMED: supportsInterface returning false -> InvalidFallbackHandler, order undiscoverable.");
    }

    /// STEP 5 -- THE ONE THAT ACTUALLY MATTERS.
    /// Call the REAL deployed GPv2Settlement.settle() with our plain contract's order.
    /// This executes the deployed EIP-1271 verification bytecode, not our own assertion.
    function test_6_realSettlementAcceptsPlainContractOrder() public {
        TestToken sell = new TestToken();
        TestToken buy = new TestToken();

        SluiceHandler.Static memory st = SluiceHandler.Static({
            sellToken: address(sell),
            buyToken: address(buy),
            sellAmount: 1 ether,
            buyAmount: 1000e18,
            validTo: uint32(block.timestamp + 1 hours)
        });
        IConditionalOrder.ConditionalOrderParams memory p = IConditionalOrder.ConditionalOrderParams({
            handler: address(handler), salt: keccak256("settle"), staticInput: abi.encode(st)
        });
        hook.createOrder(p);

        // fund + approve exactly as a real trader would
        sell.mint(address(hook), 1 ether);
        hook.approveToken(address(sell), SETTLEMENT.vaultRelayer(), type(uint256).max);
        buy.mint(address(SETTLEMENT), 1000e18); // counterparty liquidity

        (GPv2Order.Data memory order, bytes memory sig) =
            CCOW.getTradeableOrderWithSignature(address(hook), p, bytes(""), new bytes32[](0));

        address[] memory tokens = new address[](2);
        tokens[0] = address(sell); tokens[1] = address(buy);
        uint256[] memory prices = new uint256[](2);
        prices[0] = 1000e18; prices[1] = 1 ether; // executedBuy = sell * p0 / p1 = buyAmount

        GPv2Trade.Data[] memory trades = new GPv2Trade.Data[](1);
        trades[0] = GPv2Trade.Data({
            sellTokenIndex: 0, buyTokenIndex: 1, receiver: order.receiver,
            sellAmount: order.sellAmount, buyAmount: order.buyAmount, validTo: order.validTo,
            appData: order.appData, feeAmount: order.feeAmount,
            flags: 2 << 5, // sell / fill-or-kill / erc20 / erc20 / scheme=Eip1271
            executedAmount: order.sellAmount,
            signature: abi.encodePacked(address(hook), sig)
        });
        GPv2Interaction.Data[][3] memory interactions;
        interactions[0] = new GPv2Interaction.Data[](0);
        interactions[1] = new GPv2Interaction.Data[](0);
        interactions[2] = new GPv2Interaction.Data[](0);

        // become an authorised solver the only way the contract allows: via its manager
        address mgr = ALLOWLIST.manager();
        vm.prank(mgr);
        IAllowListAdmin(address(ALLOWLIST)).addSolver(address(this));
        assertTrue(ALLOWLIST.isSolver(address(this)), "solver not added");

        uint256 before = buy.balanceOf(address(hook));
        SETTLEMENT.settle(tokens, prices, trades, interactions);
        uint256 got = buy.balanceOf(address(hook)) - before;

        assertEq(got, 1000e18, "hook did not receive the buy tokens");
        assertEq(sell.balanceOf(address(hook)), 0, "sell tokens not pulled");
        console2.log("REAL GPv2Settlement.settle() executed. Hook received buyToken:", got);
    }

    /// MUTATION TEST: if test_6 is real, flipping our ERC-1271 answer must turn settle() RED.
    /// If this passes with sabotage on, test_6 proves nothing.
    function test_6b_mutation_wrongMagicValueBreaksRealSettlement() public {
        TestToken sell = new TestToken();
        TestToken buy = new TestToken();
        SluiceHandler.Static memory st = SluiceHandler.Static({
            sellToken: address(sell), buyToken: address(buy),
            sellAmount: 1 ether, buyAmount: 1000e18, validTo: uint32(block.timestamp + 1 hours)
        });
        IConditionalOrder.ConditionalOrderParams memory p = IConditionalOrder.ConditionalOrderParams({
            handler: address(handler), salt: keccak256("mutate"), staticInput: abi.encode(st)
        });
        hook.createOrder(p);
        sell.mint(address(hook), 1 ether);
        hook.approveToken(address(sell), SETTLEMENT.vaultRelayer(), type(uint256).max);
        buy.mint(address(SETTLEMENT), 1000e18);

        (GPv2Order.Data memory order, bytes memory sig) =
            CCOW.getTradeableOrderWithSignature(address(hook), p, bytes(""), new bytes32[](0));

        address[] memory tokens = new address[](2);
        tokens[0] = address(sell); tokens[1] = address(buy);
        uint256[] memory prices = new uint256[](2);
        prices[0] = 1000e18; prices[1] = 1 ether;
        GPv2Trade.Data[] memory trades = new GPv2Trade.Data[](1);
        trades[0] = GPv2Trade.Data({
            sellTokenIndex: 0, buyTokenIndex: 1, receiver: order.receiver,
            sellAmount: order.sellAmount, buyAmount: order.buyAmount, validTo: order.validTo,
            appData: order.appData, feeAmount: order.feeAmount, flags: 2 << 5,
            executedAmount: order.sellAmount, signature: abi.encodePacked(address(hook), sig)
        });
        GPv2Interaction.Data[][3] memory interactions;
        interactions[0] = new GPv2Interaction.Data[](0);
        interactions[1] = new GPv2Interaction.Data[](0);
        interactions[2] = new GPv2Interaction.Data[](0);

        vm.prank(ALLOWLIST.manager());
        IAllowListAdmin(address(ALLOWLIST)).addSolver(address(this));

        hook.setSabotage(true);
        vm.expectRevert(bytes("GPv2: invalid eip1271 signature"));
        SETTLEMENT.settle(tokens, prices, trades, interactions);
        console2.log("MUTATION CONFIRMED: wrong magic value -> real settlement reverts. test_6 is not vacuous.");
    }

    /// NEGATIVE CONTROL: an order that was never create()d must be REJECTED by real settlement.
    function test_7_unauthorisedOrderIsRejectedByRealSettlement() public {
        TestToken sell = new TestToken();
        TestToken buy = new TestToken();
        SluiceHandler.Static memory st = SluiceHandler.Static({
            sellToken: address(sell), buyToken: address(buy),
            sellAmount: 1 ether, buyAmount: 1000e18, validTo: uint32(block.timestamp + 1 hours)
        });
        IConditionalOrder.ConditionalOrderParams memory p = IConditionalOrder.ConditionalOrderParams({
            handler: address(handler), salt: keccak256("NEVER-CREATED"), staticInput: abi.encode(st)
        });
        // deliberately NOT calling hook.createOrder(p)

        GPv2Order.Data memory order = handler.getTradeableOrder(address(hook), address(0), bytes32(0), abi.encode(st), bytes(""));
        bytes memory sig = abi.encode(order, IComposableCoW.PayloadStruct({
            proof: new bytes32[](0), params: p, offchainInput: bytes("")
        }));

        sell.mint(address(hook), 1 ether);
        hook.approveToken(address(sell), SETTLEMENT.vaultRelayer(), type(uint256).max);
        buy.mint(address(SETTLEMENT), 1000e18);

        address[] memory tokens = new address[](2);
        tokens[0] = address(sell); tokens[1] = address(buy);
        uint256[] memory prices = new uint256[](2);
        prices[0] = 1000e18; prices[1] = 1 ether;
        GPv2Trade.Data[] memory trades = new GPv2Trade.Data[](1);
        trades[0] = GPv2Trade.Data({
            sellTokenIndex: 0, buyTokenIndex: 1, receiver: order.receiver,
            sellAmount: order.sellAmount, buyAmount: order.buyAmount, validTo: order.validTo,
            appData: order.appData, feeAmount: order.feeAmount, flags: 2 << 5,
            executedAmount: order.sellAmount, signature: abi.encodePacked(address(hook), sig)
        });
        GPv2Interaction.Data[][3] memory interactions;
        interactions[0] = new GPv2Interaction.Data[](0);
        interactions[1] = new GPv2Interaction.Data[](0);
        interactions[2] = new GPv2Interaction.Data[](0);

        vm.prank(ALLOWLIST.manager());
        IAllowListAdmin(address(ALLOWLIST)).addSolver(address(this));

        // NOTE: our own revert propagates out of GPv2Signing`s call and aborts the WHOLE batch,
        // rather than being caught and scored as a bad signature. See EXECUTION notes.
        vm.expectRevert(PlainOwnerHook.NotAuthed.selector);
        SETTLEMENT.settle(tokens, prices, trades, interactions);
        console2.log("Unauthorised order REJECTED by real settlement (revert bubbles, aborting the batch).");
    }

    /// TASK 3: is the solver allowlist permissionless?
    function test_5_solverAllowlistIsGated() public view {
        address mgr = ALLOWLIST.manager();
        console2.log("GPv2AllowListAuthentication.manager():", mgr);
        assertTrue(mgr != address(0), "no manager");
        assertFalse(ALLOWLIST.isSolver(address(this)), "random address should not be a solver");
    }
}
