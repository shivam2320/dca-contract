// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "solmate/tokens/ERC20.sol";

struct SwapDescriptionV2 {
    address srcToken;
    address dstToken;
    address[] srcReceivers; // transfer src token to these addresses, default
    uint256[] srcAmounts;
    address[] feeReceivers;
    uint256[] feeAmounts;
    address dstReceiver;
    uint256 amount;
    uint256 minReturnAmount;
    uint256 flags;
    bytes permit;
}

/// @dev  use for swapGeneric and swap to avoid stack too deep
struct SwapExecutionParams {
    address callTarget; // call this address
    address approveTarget; // approve this address if _APPROVE_FUND set
    bytes targetData;
    SwapDescriptionV2 desc;
    bytes clientData;
}

enum Frequency {
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

interface IKyberSwap {
    function swap(
        SwapExecutionParams calldata execution
    ) external payable returns (uint256 returnAmount, uint256 gasUsed);
}

contract DCA {
    IKyberSwap public kyberSwap;

    uint256 private _positionCounter;

    mapping(uint256 => DCAData) private positionData;

    error InvalidCaller();
    error InvalidToken();
    error InvalidAmount();
    error PositionClosed();

    event PositionCreated(uint256 positionId);
    event PositionFilled(
        uint256 positionId,
        uint256 filledFrequency,
        address filler
    );
    event PositionClosed(uint256 positionId, uint256 returnedAmount);

    constructor(IKyberSwap _kyberSwap) {
        kyberSwap = _kyberSwap;
    }

    function getPositionDetails(
        uint256 _positionId
    ) external view returns (DCAData memory) {
        return positionData[_positionId];
    }

    function createPosition(
        DCAData memory dcaData
    ) external returns (uint256 positionId) {
        ERC20(dcaData.srcToken).transferFrom(
            dcaData.user,
            address(this),
            dcaData.depositFrequency * dcaData.depositAmount
        );
        _positionCounter++;
        positionData[_positionCounter] = dcaData;

        positionId = _positionCounter;

        emit PositionCreated(positionId);
    }

    function fillPosition(
        uint256 _positionId,
        SwapExecutionParams calldata execution
    ) external {
        DCAData memory _data = positionData[_positionId];

        if (!dcaData.isOpen) revert PositionClosed();
        if (execution.desc.dstToken != _data.dstToken) revert InvalidToken();
        if (execution.desc.srcToken != _data.srcToken) revert InvalidToken();
        if (execution.desc.amount != _data.depositAmount)
            revert InvalidAmount();

        (uint256 returnAmount, ) = IKyberSwap(kyberSwap).swap(execution);

        positionData[_positionId].dcaTokenBalance += returnAmount;

        positionData[_positionId].filledFrequency += 1;

        emit PositionFilled(
            _positionId,
            positionData[_positionId].filledFrequency,
            msg.sender
        );
    }

    function closePosition(uint256 _positionId) external {
        DCAData memory _data = positionData[_positionId];
        if (msg.sender != _data.user) revert InvalidCaller();
        positionData[_positionId].isOpen = false;
        ERC20(dcaData.srcToken).transfer(
            address(this),
            dcaData.user,
            (dcaData.depositFrequency - dcaData.filledFrequency) *
                dcaData.depositAmount
        );

        emit PositionClosed(
            _positionId,
            (dcaData.depositFrequency - dcaData.filledFrequency) *
                dcaData.depositAmount
        );
    }
}