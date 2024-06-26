// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20, IERC20, IERC20Metadata} from "openzeppelin/token/ERC20/ERC20.sol";
import {IERC4626} from "openzeppelin/interfaces/IERC4626.sol";
import {ERC20Permit, IERC20Permit} from "openzeppelin/token/ERC20/extensions/ERC20Permit.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "openzeppelin/utils/math/SafeCast.sol";
import {Math} from "openzeppelin/utils/math/Math.sol";
import {Ownable} from "owner-manager-contracts/Ownable.sol";
import {TwabController, SPONSORSHIP_ADDRESS} from "pt-v5-twab-controller/TwabController.sol";
import {VaultHooks} from "pt-v5-vault/interfaces/IVaultHooks.sol";
import {SD59x18, sd, unwrap, convert} from "prb-math/SD59x18.sol";

import {DrawCalculation} from "./libraries/Draw.sol";

/* ============ Errors ============ */

/// @notice Emitted when the Yield Vault is set to the zero address.
error YieldVaultZeroAddress();

/// @notice Emitted when the Prize Pool is set to the zero address.
error PrizePoolZeroAddress();

/// @notice Emitted when the Owner is set to the zero address.
error OwnerZeroAddress();

/**
 * @notice Emitted when the underlying asset passed to the constructor is different from the YieldVault one.
 * @param asset Address of the underlying asset passed to the constructor
 * @param yieldVaultAsset Address of the YieldVault underlying asset
 */
error UnderlyingAssetMismatch(address asset, address yieldVaultAsset);

/**
 * @notice Emitted when the amount being deposited for the receiver is greater than the max amount allowed.
 * @param receiver The receiver of the deposit
 * @param amount The amount to deposit
 * @param max The max deposit amount allowed
 */
error DepositMoreThanMax(address receiver, uint256 amount, uint256 max);

/**
 * @notice Emitted when the amount being minted for the receiver is greater than the max amount allowed.
 * @param receiver The receiver of the mint
 * @param amount The amount to mint
 * @param max The max mint amount allowed
 */
error MintMoreThanMax(address receiver, uint256 amount, uint256 max);

/**
 * @notice Emitted when the amount being withdrawn for the owner is greater than the max amount allowed.
 * @param owner The owner of the assets
 * @param amount The amount to withdraw
 * @param max The max withdrawable amount
 */
error WithdrawMoreThanMax(address owner, uint256 amount, uint256 max);

/**
 * @notice Emitted when the amount being redeemed for owner is greater than the max allowed amount.
 * @param owner The owner of the assets
 * @param amount The amount to redeem
 * @param max The max redeemable amount
 */
error RedeemMoreThanMax(address owner, uint256 amount, uint256 max);

/// @notice Emitted when `_deposit` is called but no shares are minted back to the receiver.
error MintZeroShares();

/// @notice Emitted when `_withdraw` is called but no assets are being withdrawn.
error WithdrawZeroAssets();

/**
 * @notice Emitted when `_withdraw` is called but the amount of assets withdrawn from the YieldVault
 *         is lower than the amount of assets requested by the caller.
 * @param requestedAssets The amount of assets requested
 * @param withdrawnAssets The amount of assets withdrawn from the YieldVault
 */
error WithdrawAssetsLTRequested(uint256 requestedAssets, uint256 withdrawnAssets);

/// @notice Emitted when `sweep` is called but no underlying assets are currently held by the Vault.
error SweepZeroAssets();

/**
 * @notice Emitted during the liquidation process when the caller is not the liquidation pair contract.
 * @param caller The caller address
 * @param liquidationPair The LP address
 */
error CallerNotLP(address caller, address liquidationPair);

/**
 * @notice Emitted during the liquidation process when the token in is not the prize token.
 * @param tokenIn The provided tokenIn address
 * @param prizeToken The prize token address
 */
error LiquidationTokenInNotPrizeToken(address tokenIn, address prizeToken);

/**
 * @notice Emitted during the liquidation process when the token out is not the vault share token.
 * @param tokenOut The provided tokenOut address
 * @param vaultShare The vault share token address
 */
error LiquidationTokenOutNotVaultShare(address tokenOut, address vaultShare);

/// @notice Emitted during the liquidation process when the liquidation amount out is zero.
error LiquidationAmountOutZero();

/**
 * @notice Emitted during the liquidation process if the amount out is greater than the available yield.
 * @param amountOut The amount out
 * @param availableYield The available yield
 */
error LiquidationAmountOutGTYield(uint256 amountOut, uint256 availableYield);

/// @notice Emitted when the Vault is under-collateralized.
error VaultUndercollateralized();

/**
 * @notice Emitted when the target token is not supported for a given token address.
 * @param token The unsupported token address
 */
error TargetTokenNotSupported(address token);

/// @notice Emitted when the Claimer is set to the zero address.
error ClaimerZeroAddress();

/**
 * @notice Emitted when the caller is not the prize claimer.
 * @param caller The caller address
 * @param claimer The claimer address
 */
error CallerNotClaimer(address caller, address claimer);

/**
 * @notice Emitted when the minted yield exceeds the yield fee shares available.
 * @param shares The amount of yield shares to mint
 * @param yieldFeeShares The accrued yield fee shares available
 */
error YieldFeeGTAvailableShares(uint256 shares, uint256 yieldFeeShares);

/**
 * @notice Emitted when the minted yield exceeds the amount of available yield in the YieldVault.
 * @param shares The amount of yield shares to mint
 * @param availableYield The amount of yield available
 */
error YieldFeeGTAvailableYield(uint256 shares, uint256 availableYield);

/// @notice Emitted when the Liquidation Pair being set is the zero address.
error LPZeroAddress();

/**
 * @notice Emitted when the yield fee percentage being set is greater than or equal to 1.
 * @param yieldFeePercentage The yield fee percentage in integer format
 * @param maxYieldFeePercentage The max yield fee percentage in integer format (this value is equal to 1 in decimal format)
 */
error YieldFeePercentageGtePrecision(uint256 yieldFeePercentage, uint256 maxYieldFeePercentage);

/**
 * @notice Emitted when the BeforeClaim prize hook fails
 * @param reason The revert reason that was thrown
 */
error BeforeClaimPrizeFailed(bytes reason);

/**
 * @notice Emitted when the AfterClaim prize hook fails
 * @param reason The revert reason that was thrown
 */
error AfterClaimPrizeFailed(bytes reason);

/// @notice Emitted when a prize is claimed for the zero address.
error ClaimRecipientZeroAddress();

/**
 * @notice Emitted when the caller of a permit function is not the owner of the assets being permitted.
 * @param caller The address of the caller
 * @param owner The address of the owner
 */
error PermitCallerNotOwner(address caller, address owner);

/**
 * @notice Emitted when a permit call on the underlying asset failed to set the spending allowance.
 * @dev This is likely thrown when the underlying asset does not support permit, but has a fallback function.
 * @param owner The owner of the assets
 * @param spender The spender of the assets
 * @param amount The amount of assets permitted
 * @param allowance The allowance after the permit was called
 */
error PermitAllowanceNotSet(address owner, address spender, uint256 amount, uint256 allowance);

error InvalidDrawPeriod(uint256 timestamp);

error DrawAlreadyFinalized(uint24 drawId);

error DrawNotFinalized(uint24 drawId);

error WinningTeamNotFound();

error InvalidRecipient(address recipient);

error InvalidAmount();

error InvalidWithdrawal();

error RandomNumberIsZero();

error PrizeAlreadySet(uint24 drawId);

// ref: https://github.com/GenerationSoftware/pt-v5-vault/blob/97f5fd14e9d25c704b9d7da87c4d9d996b7dec41/src/Vault.sol
contract VaultV2 is IERC4626, ERC20Permit, Ownable {
    using Math for uint256;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    struct Draw {
        uint24 drawId;
        uint256 drawStartTime;
        uint256 drawEndTime;
        uint256 availableYieldAtStart;
        uint256 availableYieldAtEnd;
    }

    struct Team {
        uint8 teamId;
        uint256 teamTwab;
        uint256 teamPoints;
        address[] teamMembers;
    }

    /* ============ Events ============ */

    /**
     * @notice Emitted when a new Vault has been deployed.
     * @param asset Address of the underlying asset used by the vault
     * @param name Name of the ERC20 share minted by the vault
     * @param symbol Symbol of the ERC20 share minted by the vault
     * @param twabController Address of the TwabController used to keep track of balances
     * @param yieldVault Address of the ERC4626 vault in which assets are deposited to generate yield
     * @param claimer Address of the claimer
     * @param yieldFeeRecipient Address of the yield fee recipient
     * @param yieldFeePercentage Yield fee percentage in integer format with 1e9 precision (50% would be 5e8)
     * @param owner Address of the contract owner
     */
    event NewVault(
        IERC20 indexed asset,
        string name,
        string symbol,
        TwabController twabController,
        IERC4626 indexed yieldVault,
        address claimer,
        address yieldFeeRecipient,
        uint256 yieldFeePercentage,
        address owner
    );

    /**
     * @notice Emitted when an account sets new hooks
     * @param account The account whose hooks are being configured
     * @param hooks The hooks being set
     */
    event SetHooks(address indexed account, VaultHooks indexed hooks);

    /**
     * @notice Emitted when yield fee is minted to the yield recipient.
     * @param caller Address that called the function
     * @param recipient Address receiving the Vault shares
     * @param shares Amount of shares minted to `recipient`
     */
    event MintYieldFee(address indexed caller, address indexed recipient, uint256 shares);

    /**
     * @notice Emitted when a new yield fee recipient has been set.
     * @param yieldFeeRecipient Address of the new yield fee recipient
     */
    event YieldFeeRecipientSet(address indexed yieldFeeRecipient);

    /**
     * @notice Emitted when a new yield fee percentage has been set.
     * @param yieldFeePercentage New yield fee percentage
     */
    event YieldFeePercentageSet(uint256 yieldFeePercentage);

    /**
     * @notice Emitted when a user sponsors the Vault.
     * @param caller Address that called the function
     * @param assets Amount of assets deposited into the Vault
     * @param shares Amount of shares minted to the caller address
     */
    event Sponsor(address indexed caller, uint256 assets, uint256 shares);

    /**
     * @notice Emitted when a user sweeps assets held by the Vault into the YieldVault.
     * @param caller Address that called the function
     * @param assets Amount of assets sweeped into the YieldVault
     */
    event Sweep(address indexed caller, uint256 assets);

    event ClaimerSet(address indexed claimer);

    /**
     * @notice Emitted when a user sweeps assets held by the Vault into the YieldVault.
     * @param drawId The draw id
     * @param recipient The recipient of the prize
     * @param amount The amount of the prize
     */
    event PrizeDistributed(uint24 indexed drawId, address indexed recipient, uint256 amount);

    event DrawFinalized(uint24 indexed drawId, uint8[] winningTeams, uint256 winningRandomNumber, uint256 prizeSize);

    event NewDrawCreated(uint24 indexed drawId, uint256 indexed drawStartPeriod, uint256 indexed drawEndPeriod);

    event PrizeClaimed(address indexed recipient, uint256 indexed amount);

    /* ============ Variables ============ */

    Draw[] public draws;

    /// The maximum amount of shares that can be minted.
    uint256 private constant UINT96_MAX = type(uint96).max;

    /// @notice Address of the underlying asset used by the Vault.
    IERC20 private immutable _asset;

    /// @notice Underlying asset decimals.
    uint8 private immutable _underlyingDecimals;

    /// @notice Fee precision denominated in 9 decimal places and used to calculate yield fee percentage.
    uint32 private constant FEE_PRECISION = 1e9;

    /// @notice Yield fee percentage represented in integer format with 9 decimal places (i.e. 10000000 = 0.01 = 1%).
    uint32 private _yieldFeePercentage;

    /// @notice The gas to give to each of the before and after prize claim hooks.
    /// This should be enough gas to mint an NFT if needed.
    uint24 private constant HOOK_GAS = 150_000;

    uint24 public currentDrawId;

    /// @notice Address of the TwabController used to keep track of balances.
    TwabController private immutable _twabController;

    /// @notice Address of the ERC4626 vault generating yield.
    IERC4626 private immutable _yieldVault;

    /// @notice Address of the PrizePool that computes prizes.
    // PrizePool private immutable _prizePool;

    /// @notice Address of the claimer.
    address private _claimer;

    /// @notice Address of the liquidation pair used to liquidate yield for prize token.
    address private _liquidationPair;

    /// @notice Address of the yield fee recipient. Receives Vault shares when `mintYieldFee` is called.
    address private _yieldFeeRecipient;

    /// @notice Total yield fee shares available. Can be minted to `_yieldFeeRecipient` by calling `mintYieldFee`.
    uint256 private _yieldFeeShares;

    SD59x18 private _oddsRate = sd(0.5e18);

    /// @notice Maps user addresses to hooks that they want to execute when prizes are won.
    mapping(address => VaultHooks) internal _hooks;

    mapping(uint24 => uint8[]) public drawIdToWinningTeamIds;

    mapping(uint24 => Team[]) public drawIdToWinningTeams;

    mapping(uint24 => mapping(uint8 => uint256)) private drawIdToWinningTeamPrizes;
    mapping(uint24 => uint256) public drawIdToPrize;

    mapping(uint24 => Draw) public drawIdToDraw;

    mapping(address => uint256) public _claimablePrize;

    mapping(uint24 => bool) public drawIsFinalized;

    mapping(uint24 => bool) public drawPrizeSet;
    /* ============ Modifiers ============ */

    /// @notice Modifier reverting if the Vault is under-collateralized.
    modifier onlyVaultCollateralized() {
        _onlyVaultCollateralized(_totalSupply(), _totalAssets());
        _;
    }

    /**
     * @notice Reverts if the Vault is under-collateralized.
     * @param _depositedAssets Assets deposited into the YieldVault
     * @param _withdrawableAssets Assets withdrawable from the YieldVault
     */
    function _onlyVaultCollateralized(uint256 _depositedAssets, uint256 _withdrawableAssets) internal pure {
        if (!_isVaultCollateralized(_depositedAssets, _withdrawableAssets)) {
            revert VaultUndercollateralized();
        }
    }

    /**
     * @notice Requires the caller to be the claimer.
     */
    modifier onlyClaimer() {
        if (msg.sender != _claimer) {
            revert CallerNotClaimer(msg.sender, _claimer);
        }
        _;
    }

    /**
     * @notice Requires the caller has amounts to claim.
     */
    modifier onlyClaimableUser(address user) {
        if (_claimablePrize[user] == 0) {
            revert InvalidRecipient(user);
        }
        _;
    }

    /* ============ Constructor ============ */

    /**
     * @notice Vault constructor
     * @dev `claimer_` can be set to address zero if none is available yet.
     * @param asset_ Address of the underlying asset used by the vault
     * @param name_ Name of the ERC20 share minted by the vault
     * @param symbol_ Symbol of the ERC20 share minted by the vault
     * @param twabController_ Address of the TwabController used to keep track of balances
     * @param yieldVault_ Address of the ERC4626 vault in which assets are deposited to generate yield
     * @param claimer_ Address of the claimer
     * @param yieldFeeRecipient_ Address of the yield fee recipient
     * @param yieldFeePercentage_ Yield fee percentage
     * @param owner_ Address that will gain ownership of this contract
     */
    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        TwabController twabController_,
        IERC4626 yieldVault_,
        address claimer_,
        address yieldFeeRecipient_,
        uint32 yieldFeePercentage_,
        address owner_
    ) ERC20(name_, symbol_) ERC20Permit(name_) Ownable(owner_) {
        if (address(yieldVault_) == address(0)) revert YieldVaultZeroAddress();
        // if (address(prizePool_) == address(0)) revert PrizePoolZeroAddress();
        if (owner_ == address(0)) revert OwnerZeroAddress();

        if (address(asset_) != yieldVault_.asset()) {
            revert UnderlyingAssetMismatch(address(asset_), yieldVault_.asset());
        }

        _setClaimer(claimer_);

        (bool success, uint8 assetDecimals) = _tryGetAssetDecimals(asset_);
        _underlyingDecimals = success ? assetDecimals : 18;
        _asset = asset_;

        _twabController = twabController_;

        _yieldVault = yieldVault_;

        _setYieldFeeRecipient(yieldFeeRecipient_);
        _setYieldFeePercentage(yieldFeePercentage_);

        // Approve once for max amount
        asset_.safeIncreaseAllowance(address(yieldVault_), type(uint256).max);

        currentDrawId = 1;

        Draw memory draw = Draw({
            drawId: currentDrawId,
            drawStartTime: block.timestamp,
            drawEndTime: block.timestamp + 7 days,
            availableYieldAtStart: _availableYieldBalance(),
            availableYieldAtEnd: 0
        });

        draws.push(draw);
        drawIdToDraw[currentDrawId] = draw;
        drawIsFinalized[currentDrawId] = false;
        emit NewDrawCreated(currentDrawId, block.timestamp, block.timestamp + 7 days);

        emit NewVault(
            asset_,
            name_,
            symbol_,
            twabController_,
            yieldVault_,
            claimer_,
            yieldFeeRecipient_,
            yieldFeePercentage_,
            owner_
        );
    }

    /* ===================================================== */
    /* ============ Public & External Functions ============ */
    /* ===================================================== */

    /* ============ ERC20 / ERC4626 functions ============ */

    /// @inheritdoc IERC4626
    function asset() external view virtual override returns (address) {
        return address(_asset);
    }

    /// @inheritdoc ERC20
    function balanceOf(address _account) public view virtual override(ERC20, IERC20) returns (uint256) {
        return _balanceOf(_account);
    }

    /// @inheritdoc IERC20Metadata
    function decimals() public view virtual override(ERC20, IERC20Metadata) returns (uint8) {
        return _underlyingDecimals;
    }

    /// @inheritdoc IERC4626
    function totalAssets() external view virtual override returns (uint256) {
        return _totalAssets();
    }

    /// @inheritdoc ERC20
    function totalSupply() public view virtual override(ERC20, IERC20) returns (uint256) {
        return _totalSupply();
    }

    /* ============ Conversion Functions ============ */

    /// @inheritdoc IERC4626
    function convertToShares(uint256 _assets) external view virtual override returns (uint256) {
        return _convertToShares(_assets, _totalSupply(), _totalAssets(), Math.Rounding.Down);
    }

    /// @inheritdoc IERC4626
    function convertToAssets(uint256 _shares) external view virtual override returns (uint256) {
        return _convertToAssets(_shares, _totalSupply(), _totalAssets(), Math.Rounding.Down);
    }

    /* ============ Max / Preview Functions ============ */

    /// @inheritdoc IERC4626
    function maxDeposit(address) external view virtual override returns (uint256) {
        uint256 _depositedAssets = _totalSupply();
        return _isVaultCollateralized(_depositedAssets, _totalAssets()) ? _maxDeposit(_depositedAssets) : 0;
    }

    /// @inheritdoc IERC4626
    function previewDeposit(uint256 _assets) external view virtual override returns (uint256) {
        return _convertToShares(_assets, _totalSupply(), _totalAssets(), Math.Rounding.Down);
    }

    /// @inheritdoc IERC4626
    function maxMint(address) external view virtual override returns (uint256) {
        uint256 _depositedAssets = _totalSupply();
        return _isVaultCollateralized(_depositedAssets, _totalAssets()) ? _maxDeposit(_depositedAssets) : 0;
    }

    /// @inheritdoc IERC4626
    function previewMint(uint256 _shares) external view virtual override returns (uint256) {
        return _convertToAssets(_shares, _totalSupply(), _totalAssets(), Math.Rounding.Up);
    }

    /// @inheritdoc IERC4626
    function maxWithdraw(address _owner) external view virtual override returns (uint256) {
        return _maxWithdraw(_owner);
    }

    /// @inheritdoc IERC4626
    function previewWithdraw(uint256 _assets) external view virtual override returns (uint256) {
        return _convertToShares(_assets, _totalSupply(), _totalAssets(), Math.Rounding.Up);
    }

    /// @inheritdoc IERC4626
    function maxRedeem(address _owner) external view virtual override returns (uint256) {
        return _maxRedeem(_owner);
    }

    /// @inheritdoc IERC4626
    function previewRedeem(uint256 _shares) external view virtual override returns (uint256) {
        return _convertToAssets(_shares, _totalSupply(), _totalAssets(), Math.Rounding.Down);
    }

    /* ============ Deposit Functions ============ */

    /**
     * @inheritdoc IERC4626
     * @dev Will revert if the Vault is under-collateralized.
     */
    function deposit(uint256 _assets, address _receiver) external virtual override returns (uint256) {
        return _depositAssets(_assets, msg.sender, _receiver, false);
    }

    /**
     * @notice Approve underlying asset with permit, deposit into the Vault and mint Vault shares to `_owner`.
     * @dev Can't be used to deposit on behalf of another user since `permit` does not accept a receiver parameter.
     *      Meaning that anyone could reuse the signature and pass an arbitrary receiver to this function.
     * @dev Will revert if the Vault is under-collateralized.
     * @param _assets Amount of assets to approve and deposit
     * @param _owner Address of the owner depositing `_assets` and signing the permit
     * @param _deadline Timestamp after which the approval is no longer valid
     * @param _v V part of the secp256k1 signature
     * @param _r R part of the secp256k1 signature
     * @param _s S part of the secp256k1 signature
     * @return uint256 Amount of Vault shares minted to `_owner`.
     */
    function depositWithPermit(uint256 _assets, address _owner, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s)
        external
        returns (uint256)
    {
        if (_owner != msg.sender) {
            revert PermitCallerNotOwner(msg.sender, _owner);
        }

        IERC20Permit(address(_asset)).permit(_owner, address(this), _assets, _deadline, _v, _r, _s);

        uint256 _allowance = _asset.allowance(_owner, address(this));
        if (_allowance != _assets) {
            revert PermitAllowanceNotSet(_owner, address(this), _assets, _allowance);
        }

        return _depositAssets(_assets, _owner, _owner, false);
    }

    /**
     * @inheritdoc IERC4626
     * @dev Will revert if the Vault is under-collateralized.
     */
    function mint(uint256 _shares, address _receiver) external virtual override returns (uint256) {
        return _depositAssets(_shares, msg.sender, _receiver, true);
    }

    /**
     * @notice Deposit assets into the Vault and delegate to the sponsorship address.
     * @dev Will revert if the Vault is under-collateralized.
     * @param _assets Amount of assets to deposit
     * @return uint256 Amount of shares minted to caller.
     */
    function sponsor(uint256 _assets) external returns (uint256) {
        address _owner = msg.sender;

        _depositAssets(_assets, _owner, _owner, false);

        if (_twabController.delegateOf(address(this), _owner) != SPONSORSHIP_ADDRESS) {
            _twabController.sponsor(_owner);
        }

        emit Sponsor(_owner, _assets, _assets);

        return _assets;
    }

    /**
     * @notice Deposit underlying assets that have been mistakenly sent to the Vault into the YieldVault.
     * @dev The deposited assets will contribute to the yield of the YieldVault.
     * @return uint256 Amount of underlying assets deposited
     */
    function sweep() external returns (uint256) {
        uint256 _assets = _asset.balanceOf(address(this));
        if (_assets == 0) revert SweepZeroAssets();

        _yieldVault.deposit(_assets, address(this));

        emit Sweep(msg.sender, _assets);

        return _assets;
    }

    /* ============ Withdraw Functions ============ */

    /// @inheritdoc IERC4626
    function withdraw(uint256 _assets, address _receiver, address _owner) external virtual override returns (uint256) {
        if (_assets > _maxWithdraw(_owner)) {
            revert WithdrawMoreThanMax(_owner, _assets, _maxWithdraw(_owner));
        }

        uint256 _depositedAssets = _totalSupply();
        uint256 _withdrawableAssets = _totalAssets();
        bool _vaultCollateralized = _isVaultCollateralized(_depositedAssets, _withdrawableAssets);

        uint256 _shares = _vaultCollateralized
            ? _assets
            : _convertToShares(_assets, _depositedAssets, _withdrawableAssets, Math.Rounding.Up);

        uint256 _withdrawnAssets = _redeem(msg.sender, _receiver, _owner, _shares, _assets, _vaultCollateralized);

        if (_withdrawnAssets < _assets) {
            revert WithdrawAssetsLTRequested(_assets, _withdrawnAssets);
        }

        return _shares;
    }

    /// @inheritdoc IERC4626
    function redeem(uint256 _shares, address _receiver, address _owner) external virtual override returns (uint256) {
        if (_shares > _maxRedeem(_owner)) {
            revert RedeemMoreThanMax(_owner, _shares, _maxRedeem(_owner));
        }

        uint256 _depositedAssets = _totalSupply();
        uint256 _withdrawableAssets = _totalAssets();
        bool _vaultCollateralized = _isVaultCollateralized(_depositedAssets, _withdrawableAssets);

        uint256 _assets = _convertToAssets(_shares, _depositedAssets, _withdrawableAssets, Math.Rounding.Down);

        return _redeem(msg.sender, _receiver, _owner, _shares, _assets, _vaultCollateralized);
    }

    /* ============ Yield Functions ============ */

    /**
     * @notice Total available yield amount accrued by this vault.
     * @return uint256 Total yield amount
     */
    function availableYieldBalance() external view returns (uint256) {
        return _availableYieldBalance();
    }

    /**
     * @notice Get the available yield fee amount accrued by this vault.
     * @return uint256 Yield fee amount
     */
    function availableYieldFeeBalance() external view returns (uint256) {
        uint256 _availableYield = _availableYieldBalance();

        if (_availableYield != 0 && _yieldFeePercentage != 0) {
            return _availableYieldFeeBalance(_availableYield);
        }

        return 0;
    }

    /**
     * @notice Mint Vault shares to the `_yieldFeeRecipient`.
     * @dev Will revert if the Vault is undercollateralized.
     *      So shares does not need to be converted to assets.
     * @dev Will revert if `_shares` is greater than `_yieldFeeShares`.
     * @dev Will revert if there is not enough yield available in the YieldVault to back `_shares`.
     * @param _shares Amount of shares to mint
     */
    function mintYieldFee(uint256 _shares) external {
        uint256 _depositedAssets = _totalSupply();
        uint256 _withdrawableAssets = _totalAssets();

        _onlyVaultCollateralized(_depositedAssets, _withdrawableAssets);

        uint256 _availableYield = _withdrawableAssets - _depositedAssets;

        if (_shares > _availableYield) {
            revert YieldFeeGTAvailableYield(_shares, _availableYield);
        }
        if (_shares > _yieldFeeShares) {
            revert YieldFeeGTAvailableShares(_shares, _yieldFeeShares);
        }

        address yieldFeeRecipient_ = _yieldFeeRecipient;
        _yieldFeeShares -= _shares;
        _mint(yieldFeeRecipient_, _shares);

        emit MintYieldFee(msg.sender, yieldFeeRecipient_, _shares);
    }

    /* ============ Draw Functions ============ */

    /**
     * @notice Start a new draw. onlyClaimer can call this function.
     * @dev Will revert if the drawStartTime is in the past.
     * drawEndTime should be: drawStartTime + 7 days
     * @param drawStartTime Start time of the draw
     * @param drawEndTime End time of the draw
     */
    function startDrawPeriod(uint256 drawStartTime, uint256 drawEndTime) external onlyClaimer {
        // check if the previous draw is finalized
        if (!drawIsFinalized[currentDrawId - 1]) {
            revert DrawNotFinalized(currentDrawId);
        }

        // revert if the drawStartTime is in the past or drawEndTime is the past or drawEndTime is less than drawStartTime
        if (drawStartTime < block.timestamp || drawEndTime < block.timestamp || drawEndTime < drawStartTime) {
            revert InvalidDrawPeriod(block.timestamp);
        }

        Draw memory draw = Draw({
            drawId: currentDrawId,
            drawStartTime: drawStartTime,
            drawEndTime: drawEndTime,
            availableYieldAtStart: _availableYieldBalance(),
            availableYieldAtEnd: 0
        });

        draws.push(draw);
        drawIdToDraw[currentDrawId] = draw;
        drawIsFinalized[currentDrawId] = false;
        emit NewDrawCreated(currentDrawId, drawStartTime, drawEndTime);
    }

    /**
     * @notice Finalize the draw and calculate the winning team. onlyClaimer can call this function.
     * @dev calculate the winning team based on the encoded Team[] input and pseudo random number
     * @param drawId id of the draw
     * @param _winningRandomNumber The winning random number for the draw
     * @param _data Team[] -> (uint8 teamId, uint256 teamTwab, uint256 teamPoints, address[] teamMembers)
     */
    function finalizeDraw(uint24 drawId, uint256 _winningRandomNumber, bytes calldata _data) external onlyClaimer {
        if (block.timestamp < drawIdToDraw[drawId].drawEndTime) {
            revert InvalidDrawPeriod(block.timestamp);
        }
        if (drawIsFinalized[drawId]) {
            revert DrawAlreadyFinalized(drawId);
        }

        if (_winningRandomNumber == 0) {
            revert RandomNumberIsZero();
        }
        Team[] memory teams = abi.decode(_data, (Team[]));
        Draw storage draw = drawIdToDraw[drawId];

        draw.availableYieldAtEnd = _availableYieldBalance();

        uint256 prize = draw.availableYieldAtEnd - draw.availableYieldAtStart;

        uint256 vaultTwabTotalSupply =
            _twabController.getTotalSupplyTwabBetween(address(this), draw.drawStartTime, draw.drawEndTime);
        SD59x18[] memory odds = _calculateTeamOdds(teams, drawId, vaultTwabTotalSupply);

        // check if the team is winner
        for (uint256 i = 0; i < teams.length; i++) {
            Team memory team = teams[i];
            SD59x18 teamContributionFraction =
                sd(SafeCast.toInt256(team.teamTwab)).div(sd(SafeCast.toInt256(vaultTwabTotalSupply)));

            uint256 teamSpecificRandomNumber = DrawCalculation.calculatePseudoRandomNumber(
                drawId, address(this), team.teamId, vaultTwabTotalSupply, _winningRandomNumber
            );

            bool isWinner = DrawCalculation.isWinner(
                teamSpecificRandomNumber, team.teamTwab, vaultTwabTotalSupply, teamContributionFraction, odds[i]
            );

            if (isWinner) {
                drawIdToWinningTeamIds[drawId].push(team.teamId);
                drawIdToWinningTeams[drawId].push(team);
            }
        }

        if (drawIdToWinningTeamIds[drawId].length == 0) {
            revert WinningTeamNotFound();
        }

        _finalizeTeamPrize(drawId);
        drawIsFinalized[drawId] = true;

        drawIdToPrize[drawId] = prize;

        emit DrawFinalized(drawId, drawIdToWinningTeamIds[drawId], _winningRandomNumber, prize);
    }

    /**
     * @notice set Distributions for each winning recipients. onlyClaimer can call this function.
     * @dev Will revert if the distribution has already set or the draw is not finalized
     * @param drawId id of the draw
     */
    function distributePrizes(uint24 drawId) external onlyClaimer {
        if (drawPrizeSet[drawId]) {
            revert PrizeAlreadySet(drawId);
        }
        if (!drawIsFinalized[drawId]) {
            revert DrawNotFinalized(drawId);
        }

        (address[] memory recipients, uint256[] memory prizes) = _getDistributions(drawId);
        for (uint256 i = 0; i < recipients.length; i++) {
            address recipient = recipients[i];
            uint256 amount = prizes[i];
            if (_claimablePrize[recipient] == 0) {
                _claimablePrize[recipient] = amount;
                emit PrizeDistributed(drawId, recipient, amount);
            } else {
                _claimablePrize[recipient] += amount;
                emit PrizeDistributed(drawId, recipient, amount);
            }
        }
        drawPrizeSet[drawId] = true;
        currentDrawId++;
    }

    /**
     * @notice claim prize for the user. onlyClaimableUser can call this function.
     * @dev Will revert if the caller has no claimable prize
     * @dev Will revert if the amount is greater than the claimable prize
     * @dev Will revert if the amount is greater than the max withdrawal amount
     * @param amount amount of the prize
     */
    function claimPrize(uint256 amount) external onlyClaimableUser(msg.sender) {
        uint256 claimablePrize = _claimablePrize[msg.sender];

        if (amount > claimablePrize) {
            revert InvalidAmount();
        }

        if (amount > _yieldVault.maxWithdraw(address(this))) {
            revert InvalidWithdrawal();
        }

        _claimablePrize[msg.sender] -= amount;

        _yieldVault.withdraw(amount, msg.sender, address(this));
        emit PrizeClaimed(msg.sender, amount);
    }

    // getDistributions for each winning team
    function getDistributions(uint24 drawId) external view returns (address[] memory, uint256[] memory) {
        return _getDistributions(drawId);
    }

    function _getDistributions(uint24 drawId) private view returns (address[] memory, uint256[] memory) {
        Team[] memory winningTeams = drawIdToWinningTeams[drawId];
        Draw memory draw = drawIdToDraw[drawId];

        uint256 totalMembers;
        for (uint256 i = 0; i < winningTeams.length; i++) {
            totalMembers += winningTeams[i].teamMembers.length;
        }

        address[] memory recipients = new address[](totalMembers);
        uint256[] memory amounts = new uint256[](totalMembers);

        uint256 counter;
        for (uint256 i = 0; i < winningTeams.length; i++) {
            Team memory team = winningTeams[i];
            uint256 teamPrize = drawIdToWinningTeamPrizes[drawId][team.teamId];

            for (uint256 j = 0; j < team.teamMembers.length; j++) {
                address recipient = team.teamMembers[j];
                uint256 userTwab =
                    _twabController.getTwabBetween(address(this), recipient, draw.drawStartTime, draw.drawEndTime);

                uint256 memberPrize = Math.mulDiv(teamPrize, userTwab, team.teamTwab);

                recipients[counter] = recipient;
                amounts[counter] = memberPrize;
                counter++;
            }
        }

        return (recipients, amounts);
    }

    // calculate total twab of winning teams
    function _winningTwabTotal(uint24 drawId) internal view returns (uint256 totalTwab) {
        Team[] memory winningTeams = drawIdToWinningTeams[drawId];
        for (uint256 i = 0; i < winningTeams.length; i++) {
            totalTwab += winningTeams[i].teamTwab;
        }
        return totalTwab;
    }

    function setOddsRate(SD59x18 oddsRate) external onlyOwner {
        _oddsRate = oddsRate;
    }

    /**
     * @notice Calculate the team odds that will be used to determine the winning team.
     * @dev Calculate the odds for each team based on the teamTwab and the total supply of the vault.
     * @param teams array of Team
     * @param drawId id of the draw
     * @param vaultTwabTotalSupply total supply twab of the vault
     * @return odds array of team odds corresponding to the teams array. odds is converted to 18 decimals
     */
    function _calculateTeamOdds(Team[] memory teams, uint24 drawId, uint256 vaultTwabTotalSupply)
        internal
        view
        returns (SD59x18[] memory odds)
    {
        odds = new SD59x18[](teams.length);
        SD59x18 convertedTotalSupply = convert(int256(vaultTwabTotalSupply));

        for (uint256 i = 0; i < teams.length; i++) {
            uint256 teamTwab = _calculateTeamTwabBetween(teams[i].teamMembers, drawId);
            SD59x18 convertedTeamPoints = convert(int256(teams[i].teamPoints));
            SD59x18 convertedTeamWab = convert(int256(teamTwab));
            // SD59x18 teamOdds = sd(1e18) -
            //     (convertedTeamWab / convertedTotalSupply);

            // 0 < _oddsRate < 1

            SD59x18 param1 = (_oddsRate * convertedTeamWab) / convertedTotalSupply;
            SD59x18 param2 = (sd(1e18) - _oddsRate) * convertedTeamPoints;

            odds[i] = param1 + param2;
        }

        return odds;
    }

    /**
     * @notice Finalize the prize for the winning team.
     * @dev Calculate the prize for each winning team based on the teamTwab and the total twab of the winning teams.
     * @param drawId id of the draw
     */
    function _finalizeTeamPrize(uint24 drawId) internal {
        Draw memory draw = drawIdToDraw[drawId];
        Team[] memory winningTeams = drawIdToWinningTeams[drawId];
        uint256 prize = draw.availableYieldAtEnd - draw.availableYieldAtStart;

        uint256 winningTeamTotalTwab = _winningTwabTotal(drawId);

        for (uint256 i = 0; i < winningTeams.length; i++) {
            uint256 teamTwab = winningTeams[i].teamTwab;

            uint256 teamPrize = Math.mulDiv(prize, teamTwab, winningTeamTotalTwab);
            drawIdToWinningTeamPrizes[drawId][winningTeams[i].teamId] = teamPrize;
        }
    }

    function getDraw(uint24 drawId) external view returns (Draw memory) {
        return drawIdToDraw[drawId];
    }

    function getCurrentDrawEndTime() external view returns (uint256) {
        return drawIdToDraw[currentDrawId].drawEndTime;
    }

    /**
     * @notice Get the total twab of the team members between the drawStartTime and drawEndTime.
     * @param teamMembers address[] of the team members
     * @param drawId id of the draw
     * @return uint256 total twab of the team
     */
    function calculateTeamTwabBetween(address[] memory teamMembers, uint24 drawId) external view returns (uint256) {
        return _calculateTeamTwabBetween(teamMembers, drawId);
    }

    /**
     * @notice Get the total twab of the team members between the drawStartTime and drawEndTime.
     * @param teamMembers address[] of the team members
     * @param drawId id of the draw
     * @return teamTwab total twab of the team
     */
    function _calculateTeamTwabBetween(address[] memory teamMembers, uint24 drawId)
        internal
        view
        returns (uint256 teamTwab)
    {
        Draw memory draw = drawIdToDraw[drawId];

        uint256 drawStartTime = draw.drawStartTime;
        uint256 drawEndTime = draw.drawEndTime;

        for (uint256 i = 0; i < teamMembers.length; i++) {
            teamTwab += _twabController.getTwabBetween(address(this), teamMembers[i], drawStartTime, drawEndTime);
        }

        return teamTwab;
    }

    /* ============ State Function ============ */

    /**
     * @notice Check if the Vault is collateralized.
     * @return bool True if the vault is collateralized, false otherwise
     */
    function isVaultCollateralized() external view returns (bool) {
        return _isVaultCollateralized(_totalSupply(), _totalAssets());
    }

    /* ============ Setter Functions ============ */

    /**
     * @notice Set claimer.
     * @param claimer_ Address of the claimer
     * @return address New claimer address
     */
    function setClaimer(address claimer_) external onlyOwner returns (address) {
        _setClaimer(claimer_);

        emit ClaimerSet(claimer_);
        return claimer_;
    }

    /**
     * @notice Sets the hooks for a winner.
     * @param hooks The hooks to set
     */
    function setHooks(VaultHooks calldata hooks) external {
        _hooks[msg.sender] = hooks;
        emit SetHooks(msg.sender, hooks);
    }

    /**
     * @notice Set liquidationPair.
     * @param liquidationPair_ New liquidationPair address
     * @return address New liquidationPair address
     */
    // function setLiquidationPair(
    //     address liquidationPair_
    // ) external onlyOwner returns (address) {
    //     if (address(liquidationPair_) == address(0)) revert LPZeroAddress();

    //     _liquidationPair = liquidationPair_;

    //     emit LiquidationPairSet(address(this), address(liquidationPair_));
    //     return address(liquidationPair_);
    // }

    /**
     * @notice Set yield fee percentage.
     * @dev Yield fee is represented in 9 decimals and can't exceed `1e9`.
     * @param yieldFeePercentage_ Yield fee percentage
     * @return uint256 New yield fee percentage
     */
    function setYieldFeePercentage(uint32 yieldFeePercentage_) external onlyOwner returns (uint256) {
        _setYieldFeePercentage(yieldFeePercentage_);

        emit YieldFeePercentageSet(yieldFeePercentage_);
        return yieldFeePercentage_;
    }

    /**
     * @notice Set fee recipient.
     * @param yieldFeeRecipient_ Address of the fee recipient
     * @return address New fee recipient address
     */
    function setYieldFeeRecipient(address yieldFeeRecipient_) external onlyOwner returns (address) {
        _setYieldFeeRecipient(yieldFeeRecipient_);

        emit YieldFeeRecipientSet(yieldFeeRecipient_);
        return yieldFeeRecipient_;
    }

    /* ============ Getter Functions ============ */

    /**
     * @notice Address of the yield fee recipient.
     * @return address Yield fee recipient address
     */
    function yieldFeeRecipient() external view returns (address) {
        return _yieldFeeRecipient;
    }

    /**
     * @notice Yield fee percentage.
     * @return uint256 Yield fee percentage
     */
    function yieldFeePercentage() external view returns (uint256) {
        return _yieldFeePercentage;
    }

    /**
     * @notice Get total yield fee accrued by this Vault.
     * @dev If the vault becomes undercollateralized, this total yield fee can be used to collateralize it.
     * @return uint256 Total accrued yield fee
     */
    function yieldFeeShares() external view returns (uint256) {
        return _yieldFeeShares;
    }

    /**
     * @notice Address of the TwabController keeping track of balances.
     * @return address TwabController address
     */
    function twabController() external view returns (address) {
        return address(_twabController);
    }

    /**
     * @notice Address of the ERC4626 vault generating yield.
     * @return address YieldVault address
     */
    function yieldVault() external view returns (address) {
        return address(_yieldVault);
    }

    /**
     * @notice Address of the LiquidationPair used to liquidate yield for prize token.
     * @return address LiquidationPair address
     */
    function liquidationPair() external view returns (address) {
        return _liquidationPair;
    }

    /**
     * @notice Address of the PrizePool that computes prizes.
     * @return address PrizePool address
     */
    // function prizePool() external view returns (address) {
    //     return address(_prizePool);
    // }

    function claimer() external view returns (address) {
        return _claimer;
    }

    /**
     * @notice Gets the hooks for the given user.
     * @param _account The user to retrieve the hooks for
     * @return VaultHooks The hooks for the given user
     */
    function getHooks(address _account) external view returns (VaultHooks memory) {
        return _hooks[_account];
    }

    /* ============================================ */
    /* ============ Internal Functions ============ */
    /* ============================================ */

    /* ============ ERC20 / ERC4626 functions ============ */

    /**
     * @notice Fetch underlying asset decimals.
     * @dev Attempts to fetch the asset decimals. A return value of false indicates that the attempt failed in some way.
     * @param asset_ Address of the underlying asset
     * @return bool True if the attempt was successful, false otherwise
     * @return uint8 Token decimals number
     */
    function _tryGetAssetDecimals(IERC20 asset_) private view returns (bool, uint8) {
        (bool success, bytes memory encodedDecimals) =
            address(asset_).staticcall(abi.encodeWithSelector(IERC20Metadata.decimals.selector));
        if (success && encodedDecimals.length >= 32) {
            uint256 returnedDecimals = abi.decode(encodedDecimals, (uint256));
            if (returnedDecimals <= type(uint8).max) {
                return (true, uint8(returnedDecimals));
            }
        }
        return (false, 0);
    }

    /**
     * @notice Get the Vault shares balance of a given account.
     * @param _account Account to get the balance for
     * @return uint256 Balance of the account
     */
    function _balanceOf(address _account) internal view returns (uint256) {
        return _twabController.balanceOf(address(this), _account);
    }

    /**
     * @notice Total amount of assets managed by this Vault.
     * @return uint256 Total amount of assets
     */
    function _totalAssets() internal view returns (uint256) {
        return _yieldVault.maxWithdraw(address(this));
    }

    /**
     * @notice Total amount of shares minted by this Vault.
     * @return uint256 Total amount of shares
     */
    function _totalSupply() internal view returns (uint256) {
        return _twabController.totalSupply(address(this));
    }

    /* ============ Conversion Functions ============ */

    /**
     * @notice Convert assets to shares.
     * @param _assets Amount of assets to convert
     * @param _depositedAssets Assets deposited into the YieldVault
     * @param _withdrawableAssets Assets withdrawable from the YieldVault
     * @param _rounding Rounding mode (i.e. down or up)
     * @return uint256 Amount of shares corresponding to the assets
     */
    function _convertToShares(
        uint256 _assets,
        uint256 _depositedAssets,
        uint256 _withdrawableAssets,
        Math.Rounding _rounding
    ) internal pure returns (uint256) {
        if (_assets == 0 || _depositedAssets == 0) {
            return _assets;
        }

        uint256 _collateralAssets = _collateral(_depositedAssets, _withdrawableAssets);

        return _collateralAssets == 0 ? 0 : _assets.mulDiv(_depositedAssets, _collateralAssets, _rounding);
    }

    /**
     * @notice Convert shares to assets.
     * @param _shares Amount of shares to convert
     * @param _depositedAssets Assets deposited into the YieldVault
     * @param _withdrawableAssets Assets withdrawable from the YieldVault
     * @param _rounding Rounding mode (i.e. down or up)
     * @return uint256 Amount of assets corresponding to the shares
     */
    function _convertToAssets(
        uint256 _shares,
        uint256 _depositedAssets,
        uint256 _withdrawableAssets,
        Math.Rounding _rounding
    ) internal pure returns (uint256) {
        if (_shares == 0 || _depositedAssets == 0) {
            return _shares;
        }

        uint256 _collateralAssets = _collateral(_depositedAssets, _withdrawableAssets);

        return _collateralAssets == 0 ? 0 : _shares.mulDiv(_collateralAssets, _depositedAssets, _rounding);
    }

    /* ============ Max / Preview Functions ============ */

    /**
     * @notice Returns the maximum amount of underlying assets that can be deposited into the Vault.
     * @dev We use type(uint96).max cause this is the type used to store balances in TwabController.
     * @param _depositedAssets Assets deposited into the YieldVault
     * @return uint256 Amount of underlying assets that can be deposited
     */
    function _maxDeposit(uint256 _depositedAssets) internal view returns (uint256) {
        uint256 _vaultMaxDeposit = UINT96_MAX - _depositedAssets;
        uint256 _yieldVaultMaxDeposit = _yieldVault.maxDeposit(address(this));

        // Vault shares are minted 1:1 when the vault is collateralized,
        // so maxDeposit and maxMint return the same value
        return _yieldVaultMaxDeposit < _vaultMaxDeposit ? _yieldVaultMaxDeposit : _vaultMaxDeposit;
    }

    /**
     * @notice Returns the maximum amount of the underlying asset that can be withdrawn
     * from the owner balance in the Vault, through a withdraw call.
     * @param _owner Address to check `maxWithdraw` for
     * @return uint256 Amount of the underlying asset that can be withdrawn
     */
    function _maxWithdraw(address _owner) internal view returns (uint256) {
        return _convertToAssets(_balanceOf(_owner), _totalSupply(), _totalAssets(), Math.Rounding.Down);
    }

    /**
     * @notice Returns the maximum amount of Vault shares that can be redeemed
     * from the owner balance in the Vault, through a redeem call.
     * @param _owner Address to check `maxRedeem` for
     * @return uint256 Amount of Vault shares that can be redeemed
     */
    function _maxRedeem(address _owner) internal view returns (uint256) {
        return _balanceOf(_owner);
    }

    /* ============ Yield Functions ============ */

    /**
     * @notice Total available yield amount accrued by this vault.
     * @dev This amount includes the liquidatable yield + yield fee amount.
     * @dev The available yield is equal to the total amount of assets managed by this Vault
     *      minus the total amount of assets supplied to the Vault and current allocated `_yieldFeeShares`.
     * @dev If `_assetsAllocated` is greater than `_withdrawableAssets`, it means that the Vault is undercollateralized.
     *      We must not mint more shares than underlying assets available so we return 0.
     * @return uint256 Total yield amount
     */
    function _availableYieldBalance() internal view returns (uint256) {
        uint256 _depositedAssets = _totalSupply();
        uint256 _withdrawableAssets = _totalAssets();
        uint256 _assetsAllocated = _convertToAssets(
            _depositedAssets + _yieldFeeShares, _depositedAssets, _withdrawableAssets, Math.Rounding.Up
        );

        return _assetsAllocated > _withdrawableAssets ? 0 : _withdrawableAssets - _assetsAllocated;
    }

    /**
     * @notice Available yield fee amount.
     * @param _availableYield Total amount of yield available
     * @return uint256 Available yield fee balance
     */
    function _availableYieldFeeBalance(uint256 _availableYield) internal view returns (uint256) {
        return (_availableYield * _yieldFeePercentage) / FEE_PRECISION;
    }

    /**
     * @notice Increase yield fee balance accrued by `_yieldFeeRecipient`.
     * @param _shares Amount of shares to increase yield fee balance by
     */
    function _increaseYieldFeeBalance(uint256 _shares) internal {
        _yieldFeeShares += _shares;
    }

    /* ============ Liquidation Functions ============ */

    /**
     * @notice Return the yield amount (available yield minus fees) that can be liquidated by minting Vault shares.
     * @param _token Address of the token to get available balance for
     * @return uint256 Available amount of `_token`
     */
    function _liquidatableBalanceOf(address _token) internal view returns (uint256) {
        if (_token != address(this)) {
            revert LiquidationTokenOutNotVaultShare(_token, address(this));
        }

        uint256 _availableYield = _availableYieldBalance();

        unchecked {
            return _availableYield -= _availableYieldFeeBalance(_availableYield);
        }
    }

    /* ============ Deposit Functions ============ */

    /**
     * @notice Deposit assets and mint shares
     * @param _caller The caller of the deposit
     * @param _receiver The receiver of the deposit shares
     * @param _assets Amount of assets to deposit
     * @dev If there are currently some underlying assets in the vault,
     *      we only transfer the difference from the user wallet into the vault.
     *      The difference is calculated this way:
     *      - if `_vaultAssets` balance is greater than 0 and lower than `_assets`,
     *        we subtract `_vaultAssets` from `_assets` and deposit `_assetsDeposit` amount into the vault
     *      - if `_vaultAssets` balance is greater than or equal to `_assets`,
     *        we know the vault has enough underlying assets to fulfill the deposit
     *        so we don't transfer any assets from the user wallet into the vault
     * @dev Will revert if 0 shares are minted back to the receiver.
     */
    function _deposit(address _caller, address _receiver, uint256 _assets) internal {
        // It is only possible to deposit when the vault is collateralized
        // Shares are backed 1:1 by assets
        if (_assets == 0) revert MintZeroShares();

        uint256 _vaultAssets = _asset.balanceOf(address(this));

        // If _asset is ERC777, `transferFrom` can trigger a reentrancy BEFORE the transfer happens through the
        // `tokensToSend` hook. On the other hand, the `tokenReceived` hook that is triggered after the transfer
        // calls the vault which is assumed to not be malicious.
        //
        // Conclusion: we need to do the transfer before we mint so that any reentrancy would happen before the
        // assets are transferred and before the shares are minted, which is a valid state.

        // We only need to deposit new assets if there is not enough assets in the vault to fulfill the deposit
        if (_assets > _vaultAssets) {
            uint256 _assetsDeposit;

            unchecked {
                if (_vaultAssets != 0) {
                    _assetsDeposit = _assets - _vaultAssets;
                }
            }

            _asset.safeTransferFrom(_caller, address(this), _assetsDeposit != 0 ? _assetsDeposit : _assets);
        }

        _yieldVault.deposit(_assets, address(this));

        _mint(_receiver, _assets);

        emit Deposit(_caller, _receiver, _assets, _assets);
    }

    /**
     * @notice Deposit assets and mint shares.
     * @dev Will revert if the Vault is under-collateralized.
     *      So assets does not need to be converted to shares.
     * @param _assets The assets to deposit
     * @param _owner The owner of the assets
     * @param _receiver The receiver of the deposit shares
     * @param _isMint Whether the function is called to mint or deposit
     * @return uint256 Amount of shares minted to `_receiver`
     */
    function _depositAssets(uint256 _assets, address _owner, address _receiver, bool _isMint)
        internal
        returns (uint256)
    {
        uint256 _depositedAssets = _totalSupply();
        uint256 _withdrawableAssets = _totalAssets();

        _onlyVaultCollateralized(_depositedAssets, _withdrawableAssets);

        if (_assets > _maxDeposit(_depositedAssets)) {
            if (_isMint) {
                revert MintMoreThanMax(_receiver, _assets, _maxDeposit(_depositedAssets));
            }

            revert DepositMoreThanMax(_receiver, _assets, _maxDeposit(_depositedAssets));
        }

        _deposit(_owner, _receiver, _assets);
        return _assets;
    }

    /* ============ Redeem Function ============ */

    /**
     * @notice Redeem/Withdraw common flow
     * @dev When the Vault is collateralized, shares are backed by assets 1:1, `withdraw` is used.
     *      When the Vault is undercollateralized, shares are not backed by assets 1:1.
     *      `redeem` is used to avoid burning too many YieldVault shares in exchange of assets.
     * @param _caller Address of the caller
     * @param _receiver Address of the receiver of the assets
     * @param _owner Owner of the shares
     * @param _shares Shares to burn
     * @param _assets Assets to withdraw
     * @param _vaultCollateralized Whether the Vault is collateralized or not
     */
    function _redeem(
        address _caller,
        address _receiver,
        address _owner,
        uint256 _shares,
        uint256 _assets,
        bool _vaultCollateralized
    ) internal returns (uint256) {
        if (_caller != _owner) {
            _spendAllowance(_owner, _caller, _shares);
        }

        uint256 _yieldVaultShares;

        if (!_vaultCollateralized) {
            _yieldVaultShares = _shares.mulDiv(_yieldVault.maxRedeem(address(this)), _totalSupply(), Math.Rounding.Down);
        }

        // If _asset is ERC777, `transfer` can trigger a reentrancy AFTER the transfer happens through the
        // `tokensReceived` hook. On the other hand, the `tokensToSend` hook, that is triggered before the transfer,
        // calls the vault, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer after the burn so that any reentrancy would happen after the
        // shares are burned and after the assets are transferred, which is a valid state.
        _burn(_owner, _shares);

        // If the Vault is collateralized, users can withdraw their deposit 1:1
        if (_vaultCollateralized) {
            _yieldVault.withdraw(_assets, _receiver, address(this));
        } else {
            // Otherwise, redeem is used to avoid burning too many YieldVault shares
            _assets = _yieldVault.redeem(_yieldVaultShares, _receiver, address(this));
        }

        if (_assets == 0) revert WithdrawZeroAssets();

        emit Withdraw(_caller, _receiver, _owner, _assets, _shares);

        return _assets;
    }

    /* ============ State Functions ============ */

    /**
     * @notice Creates `_shares` tokens and assigns them to `_receiver`, increasing the total supply.
     * @dev Emits a {Transfer} event with `from` set to the zero address.
     * @dev `_receiver` cannot be the zero address.
     * @param _receiver Address that will receive the minted shares
     * @param _shares Shares to mint
     */
    function _mint(address _receiver, uint256 _shares) internal virtual override {
        _twabController.mint(_receiver, SafeCast.toUint96(_shares));
        emit Transfer(address(0), _receiver, _shares);
    }

    /**
     * @notice Destroys `_shares` tokens from `_owner`, reducing the total supply.
     * @dev Emits a {Transfer} event with `to` set to the zero address.
     * @dev `_owner` cannot be the zero address.
     * @dev `_owner` must have at least `_shares` tokens.
     * @param _owner The owner of the shares
     * @param _shares The shares to burn
     */
    function _burn(address _owner, uint256 _shares) internal virtual override {
        _twabController.burn(_owner, SafeCast.toUint96(_shares));
        emit Transfer(_owner, address(0), _shares);
    }

    /**
     * @notice Updates `_from` and `_to` TWAB balance for a transfer.
     * @dev `_from` cannot be the zero address.
     * @dev `_to` cannot be the zero address.
     * @dev `_from` must have a balance of at least `_shares`.
     * @param _from Address to transfer from
     * @param _to Address to transfer to
     * @param _shares Shares to transfer
     */
    function _transfer(address _from, address _to, uint256 _shares) internal virtual override {
        _twabController.transfer(_from, _to, SafeCast.toUint96(_shares));
        emit Transfer(_from, _to, _shares);
    }

    /**
     * @notice Returns the quantity of withdrawable underlying assets held as collateral by the YieldVault.
     * @dev When the Vault is collateralized, Vault shares are minted at a 1:1 ratio based on the user's deposited underlying assets.
     *      The total supply of shares corresponds directly to the total amount of underlying assets deposited into the YieldVault.
     *      Users have the ability to withdraw only the quantity of underlying assets they initially deposited,
     *      without access to any of the accumulated yield within the YieldVault.
     * @dev In case of undercollateralization, any remaining collateral within the YieldVault can be withdrawn.
     *      Withdrawals can be made by users for their corresponding deposit shares.
     * @param _depositedAssets Assets deposited into the YieldVault
     * @param _withdrawableAssets Assets withdrawable from the YieldVault
     * @return uint256 Available collateral
     */
    function _collateral(uint256 _depositedAssets, uint256 _withdrawableAssets) internal pure returns (uint256) {
        // If the Vault is collateralized, users can only withdraw the amount of underlying assets they deposited.
        if (_isVaultCollateralized(_depositedAssets, _withdrawableAssets)) {
            return _depositedAssets;
        }

        // Otherwise, any remaining collateral within the YieldVault is available
        // and distributed proportionally among depositors.
        return _withdrawableAssets;
    }

    /**
     * @notice Check if the Vault is collateralized.
     * @dev The vault is collateralized if the total amount of underlying assets currently held by the YieldVault
     *      is greater than or equal to the total supply of shares minted by the Vault.
     * @param _depositedAssets Assets deposited into the YieldVault
     * @param _withdrawableAssets Assets withdrawable from the YieldVault
     * @return bool True if the vault is collateralized, false otherwise
     */
    function _isVaultCollateralized(uint256 _depositedAssets, uint256 _withdrawableAssets)
        internal
        pure
        returns (bool)
    {
        return _withdrawableAssets >= _depositedAssets;
    }

    /* ============ Setter Functions ============ */

    /**
     * @notice Set claimer address.
     * @dev Will revert if `claimer_` is address zero.
     * @param claimer_ Address of the claimer
     */
    function _setClaimer(address claimer_) internal {
        if (claimer_ == address(0)) revert ClaimerZeroAddress();
        _claimer = claimer_;
    }

    /**
     * @notice Set yield fee percentage.
     * @dev Yield fee is represented in 9 decimals and can't exceed or equal `1e9`.
     * @param yieldFeePercentage_ The new yield fee percentage to set
     */
    function _setYieldFeePercentage(uint32 yieldFeePercentage_) internal {
        if (yieldFeePercentage_ >= FEE_PRECISION) {
            revert YieldFeePercentageGtePrecision(yieldFeePercentage_, FEE_PRECISION);
        }
        _yieldFeePercentage = yieldFeePercentage_;
    }

    /**
     * @notice Set yield fee recipient address.
     * @param yieldFeeRecipient_ Address of the fee recipient
     */
    function _setYieldFeeRecipient(address yieldFeeRecipient_) internal {
        _yieldFeeRecipient = yieldFeeRecipient_;
    }
}
