// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

enum Frequency {
    HOURLY,
    DAILY,
    WEEKLY,
    MONTHLY
}

struct DCAData {
    Frequency frequency;
    address user;
    address dstToken;
    address srcToken;
    uint256 depositAmount;
    uint256 depositFrequency;
    uint256 filledFrequency;
    uint256 dcaTokenBalance;
    bool isOpen;
}

/// @title DCA contract
contract DCATool is AccessControl, Initializable {
    using SafeERC20 for IERC20;

    /// @dev Address of Zebra swap router
    IUniswapV2Router02 public swapRouter;

    /// @dev Address to represent native token
    address private constant NATIVE_TOKEN_ADDRESS =
        address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    /// @dev Counter to track positions
    uint256 private _positionCounter;

    /// @dev Protocol fees for managing positions
    uint256 private _fees;

    /// @dev FILLER role
    bytes32 public constant FILLER = keccak256("FILLER");

    /// @dev Mapping to track of fees collected in a specific token
    mapping(address => uint256) private collectedFees;

    /// @dev Mapping to map position id with dca data
    mapping(uint256 => DCAData) public positionData;

    /// @dev Address of Zebra swap router
    mapping(address => uint256[]) public userPositionIds;

    /// @dev Error if position is already filled
    error PositionAlreadyFilled();

    /// @dev Error if position is closed
    error PositionClosed();

    /// @dev Error if caller address is invalid
    error InvalidCaller();

    /// @dev Error if amount is invalid
    error InvalidAmount();

    /// @dev Trigger when new position is created
    event PositionCreated(uint256 positionId);

    /// @dev Trigger when position is filled
    event PositionFilled(
        uint256 positionId,
        uint256 filledFrequency,
        address filler
    );

    /// @dev Trigger when position is closed
    event PositionClose(uint256 positionId, uint256 returnedAmount);

    /// @dev initialize Function to initialize this contract
    /// @param _swapRouter Address of Zebra swap router
    function initialize(IUniswapV2Router02 _swapRouter) external initializer {
        swapRouter = _swapRouter;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(FILLER, msg.sender);
    }

    /// @dev Returns all positions for a particular user
    /// @param user Address of user
    function getUserPositions(
        address user
    ) external view returns (DCAData[] memory) {
        uint256[] memory positionIds = userPositionIds[user];
        DCAData[] memory data = new DCAData[](positionIds.length);

        for (uint i; i < positionIds.length; ) {
            data[i] = positionData[positionIds[i]];
            unchecked {
                ++i;
            }
        }
        return data;
    }

    /// @dev This function is used to create new dca position
    /// @param dcaData DCAData struct
    function createPosition(
        DCAData memory dcaData
    ) external payable returns (uint256 positionId) {
        uint256 totalAmount = dcaData.depositFrequency * dcaData.depositAmount;
        uint256 fees;
        if (_fees != 0) {
            fees = (_fees * totalAmount) / 10000;
            collectedFees[dcaData.srcToken] += fees;
        }
        if (dcaData.srcToken == NATIVE_TOKEN_ADDRESS) {
            if (msg.value != totalAmount + fees) revert InvalidAmount();
        } else {
            IERC20(dcaData.srcToken).safeTransferFrom(
                dcaData.user,
                address(this),
                totalAmount + fees
            );
        }
        _positionCounter++;
        positionData[_positionCounter] = dcaData;

        positionId = _positionCounter;
        userPositionIds[dcaData.user].push(positionId);

        emit PositionCreated(positionId);
    }

    /// @dev This function is used to fill positions
    /// @dev Can only be called by Filler
    /// @param _positionId Id of position to fill
    function fillPosition(uint256 _positionId) public onlyRole(FILLER) {
        DCAData memory _data = positionData[_positionId];

        if (!_data.isOpen) revert PositionClosed();
        if (_data.depositFrequency == _data.filledFrequency)
            revert PositionAlreadyFilled();

        uint256 returnAmount;
        if (_data.srcToken == NATIVE_TOKEN_ADDRESS) {
            returnAmount = swapNative(
                _data.dstToken,
                _data.user,
                _data.depositAmount
            );
        } else {
            returnAmount = swapERC20(
                _data.srcToken,
                _data.dstToken,
                _data.depositAmount,
                _data.user
            );
        }

        positionData[_positionId].dcaTokenBalance += returnAmount;

        positionData[_positionId].filledFrequency += 1;

        emit PositionFilled(
            _positionId,
            positionData[_positionId].filledFrequency,
            msg.sender
        );
    }

    /// @dev This function is used to fill positions in bulk
    /// @dev Can only be called by Filler
    /// @param _positionIds Ids of positions to fill
    function bulkFillPosition(
        uint256[] calldata _positionIds
    ) external onlyRole(FILLER) {
        uint256 leng = _positionIds.length;
        for (uint256 i; i < leng; ) {
            fillPosition(_positionIds[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev This function is used to close position
    /// @dev Can only be called by user of position
    /// @param _positionId Id of position to close
    function closePosition(uint256 _positionId) external {
        DCAData memory _data = positionData[_positionId];
        if (msg.sender != _data.user) revert InvalidCaller();
        positionData[_positionId].isOpen = false;
        IERC20(_data.srcToken).safeTransfer(
            _data.user,
            (_data.depositFrequency - _data.filledFrequency) *
                _data.depositAmount
        );

        emit PositionClose(
            _positionId,
            (_data.depositFrequency - _data.filledFrequency) *
                _data.depositAmount
        );
    }

    // @notice function responsible to swap ERC20 -> ERC20
    // @param _tokenIn address of input token
    // @param _tokenOut address of output token
    // @param amountIn amount of input tokens
    function swapERC20(
        address _tokenIn,
        address _tokenOut,
        uint256 amountIn,
        address _receiver
    ) private returns (uint256 amountOut) {
        uint256[] memory amountsOut;

        IERC20(_tokenIn).forceApprove(address(swapRouter), amountIn);

        address[] memory path = new address[](2);
        path[0] = _tokenIn;
        path[1] = _tokenOut;

        if (_tokenOut == 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE) {
            path[1] = swapRouter.WETH();
            amountsOut = swapRouter.getAmountsOut(amountIn, path);
            swapRouter.swapExactTokensForETH(
                amountIn,
                amountsOut[path.length - 1],
                path,
                _receiver,
                block.timestamp + 20
            );

            amountOut = amountsOut[path.length - 1];
        } else {
            amountsOut = swapRouter.getAmountsOut(amountIn, path);
            swapRouter.swapExactTokensForTokens(
                amountIn,
                amountsOut[path.length - 1],
                path,
                _receiver,
                block.timestamp + 20
            );

            amountOut = amountsOut[path.length - 1];
        }
    }

    /// @notice function responsible to swap NATIVE -> ERC20
    /// @param _tokenOut Address of token to swap
    /// @param _receiver Address of receiver
    /// @param _swapAmount Amount to swap
    function swapNative(
        address _tokenOut,
        address _receiver,
        uint256 _swapAmount
    ) private returns (uint256 amountOut) {
        uint256[] memory amountsOut;

        //swapExactETHfortokens
        address[] memory path = new address[](2);
        path[0] = swapRouter.WETH();
        path[1] = _tokenOut;

        amountsOut = swapRouter.getAmountsOut(_swapAmount, path);

        swapRouter.swapExactETHForTokens{value: _swapAmount}(
            amountsOut[path.length - 1],
            path,
            _receiver,
            block.timestamp + 20
        );

        amountOut = amountsOut[path.length - 1];
    }

    /// @notice This function is responsible for changing protocol fees
    /// @dev onlyAdmin can call this function
    /// @param _newFees New fees
    function changeFees(
        uint256 _newFees
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _fees = _newFees;
    }

    /// @notice This function is responsible for withdrawing protocol fees
    /// @dev onlyAdmin can call this function
    /// @param  _tokens addresses of tokens to withdraw fees
    function withdrawFees(
        address[] memory _tokens
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint i; i < _tokens.length; ) {
            IERC20(_tokens[i]).safeTransfer(
                msg.sender,
                collectedFees[_tokens[i]]
            );
            unchecked {
                ++i;
            }
        }
    }

    /// @notice function responsible to rescue tokens if any
    /// @dev onlyAdmin can access this function
    /// @param  tokenAddr address of locked token
    function rescueFunds(
        address tokenAddr
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (tokenAddr == NATIVE_TOKEN_ADDRESS) {
            uint256 balance = address(this).balance;
            payable(msg.sender).transfer(balance);
        } else {
            uint256 balance = IERC20(tokenAddr).balanceOf(address(this));
            IERC20(tokenAddr).safeTransfer(msg.sender, balance);
        }
    }
}
