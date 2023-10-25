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

struct DCAData {
    address user;
    address dcaToken;
    address depositToken;
    uint256 depositAmount;
    uint256 totalDepositAmount;
    uint256 numOfDays;
    uint256 filledDays;
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
    error DaysNotYetFilled();
    error InvalidToken();
    error InvalidAmount();

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
        ERC20(dcaData.depositToken).transferFrom(
            dcaData.user,
            address(this),
            dcaData.totalDepositAmount
        );
        _positionCounter++;
        positionData[_positionCounter] = dcaData;

        positionId = _positionCounter;
    }

    function fillPosition(
        uint256 _positionId,
        SwapExecutionParams calldata execution
    ) external {
        DCAData memory _data = positionData[_positionId];

        if (execution.desc.dstToken != _data.dcaToken) revert InvalidToken();
        if (execution.desc.srcToken != _data.depositToken)
            revert InvalidToken();
        if (execution.desc.amount != _data.depositAmount)
            revert InvalidAmount();

        (uint256 returnAmount, ) = IKyberSwap(kyberSwap).swap(execution);

        positionData[_positionId].dcaTokenBalance += returnAmount;

        positionData[_positionId].filledDays += 1;
    }

    function withdrawPosition(uint256 _positionId) external {
        DCAData memory _data = positionData[_positionId];
        if (msg.sender != _data.user) revert InvalidCaller();
        positionData[_positionId].isOpen = false;
    }
}
