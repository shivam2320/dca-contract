// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
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

contract DCATool is AccessControl {
    using SafeERC20 for IERC20;

    IUniswapV2Router02 public swapRouter;

    address private constant NATIVE_TOKEN_ADDRESS =
        address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    uint256 private _positionCounter;

    bytes32 public constant FILLER = keccak256("FILLER");

    mapping(uint256 => DCAData) private positionData;

    error PositionAlreadyFilled();
    error PositionClosed();
    error InvalidCaller();

    event PositionCreated(uint256 positionId);
    event PositionFilled(
        uint256 positionId,
        uint256 filledFrequency,
        address filler
    );
    event PositionClose(uint256 positionId, uint256 returnedAmount);

    constructor(IUniswapV2Router02 _swapRouter) {
        swapRouter = _swapRouter;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(FILLER, msg.sender);
    }

    function getPositionDetails(
        uint256 _positionId
    ) external view returns (DCAData memory) {
        return positionData[_positionId];
    }

    function createPosition(
        DCAData memory dcaData
    ) external returns (uint256 positionId) {
        IERC20(dcaData.srcToken).safeTransferFrom(
            dcaData.user,
            address(this),
            dcaData.depositFrequency * dcaData.depositAmount
        );
        _positionCounter++;
        positionData[_positionCounter] = dcaData;

        positionId = _positionCounter;

        emit PositionCreated(positionId);
    }

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

    /**
    // @notice function responsible to swap ERC20 -> ERC20
    // @param _tokenIn address of input token
    // @param _tokenOut address of output token
    // @param amountIn amount of input tokens
    // param extraData extra data if required
     */
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

    /**
    // @notice function responsible to swap NATIVE -> ERC20
    // @param _tokenOut address of output token
    // param extraData extra data if required
     */
    function swapNative(
        address _tokenOut,
        address _receiver,
        uint256 _depositAmount
    ) private returns (uint256 amountOut) {
        uint256[] memory amountsOut;

        //swapExactETHfortokens
        address[] memory path = new address[](2);
        path[0] = swapRouter.WETH();
        path[1] = _tokenOut;

        amountsOut = swapRouter.getAmountsOut(_depositAmount, path);

        swapRouter.swapExactETHForTokens{value: _depositAmount}(
            amountsOut[path.length - 1],
            path,
            _receiver,
            block.timestamp + 20
        );

        amountOut = amountsOut[path.length - 1];
    }
}
