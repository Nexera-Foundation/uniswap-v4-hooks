// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

//import {OAppRead} from "@layerzerolabs/oapp-evm/contracts/interfaces/IOAppMapper.sol";
import {IOAppReducer} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppReducer.sol";
import {OAppRead} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppRead.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {ReadCodecV1, EVMCallRequestV1, EVMCallComputeV1} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/ReadCodecV1.sol";
import {MessagingFee, MessagingReceipt, Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import {StatCollectorHook} from "./StatCollectorHook.sol";

abstract contract LZReadStatDataProvider is StatCollectorHook, OAppRead, IOAppReducer {
    using OptionsBuilder for bytes;

    /// @dev Valid LZ Read channel ids start from `eid > 4294965694` (which is `type(uint32).max - 1600`).
    uint32 internal constant LZ_READ_CHANNEL_EID_THRESHOLD = 4294965694;

    /// @dev Constant used by LZ `ReadCodecV1.encode()` to specify caller app label for use with compute logic (0 is default)
    uint16 private constant OAPP_READ_APP_LABEL = 0;

    /// @dev Gas limit for lzRead results callback
    uint128 private constant READ_CALLBACK_GAS_LIMIT = 300000;

    uint32 private immutable _eid;
    uint32 private immutable _readChannel;
    uint16 private immutable _confirmations;

    struct StatData {
        uint256 liquidity0;
        uint256 liquidity1;
        uint256 fee0;
        uint256 fee1;
    }

    uint256 feeRateReadingInterval; //Interval for calculating fee rate
    uint256 intermediateLiquidityPoints; //How many additional timestamps to add for more precise liquidity estimation

    uint256 lastFeeRateUpdateTimestamp; // Timestamp when last fee rate was calculated
    uint256 lastFeeRate; // Last calculated fee rate multiplied to 1e18

    /**
     * @param readChannel Read channel used to read on current chain
     */
    constructor(uint32 eid, uint32 readChannel, uint16 confirmations) {
        _eid = eid;
        _readChannel = readChannel;
        setReadChannel(readChannel, true);
        _confirmations = confirmations;
    }

    function setConfig(uint256 feeRateReadingInterval_, uint256 intermediateLiquidityPoints_) external onlyOwner {
        feeRateReadingInterval = feeRateReadingInterval_;
        intermediateLiquidityPoints = intermediateLiquidityPoints_;
    }

    function initiateReadFeeRate() external payable returns (MessagingReceipt memory receipt) {
        bytes memory readCmd = _encodeReadStatDataCall(_prepareFeeRateReadTimestamps());
        bytes memory opts = OptionsBuilder.newOptions().addExecutorLzReadOption(READ_CALLBACK_GAS_LIMIT, uint32(readCmd.length), 0);
        return _lzSend(_readChannel, readCmd, opts, MessagingFee(msg.value, 0), payable(msg.sender));
    }

    function _prepareFeeRateReadTimestamps() internal view returns (uint64[] memory timestamps) {
        timestamps = new uint64[](2 + intermediateLiquidityPoints);
        uint64 nowTimestamp = uint64(block.timestamp);
        uint64 startTimestamp = nowTimestamp - uint64(feeRateReadingInterval);
        timestamps[0] = startTimestamp;
        timestamps[timestamps.length - 1] = nowTimestamp;

        if (intermediateLiquidityPoints == 0) {
            uint64 liquidityReadInterval = uint64((nowTimestamp - startTimestamp) / intermediateLiquidityPoints);
            uint64 next = startTimestamp;
            for (uint256 i = 1; i <= intermediateLiquidityPoints; i++) {
                next += liquidityReadInterval;
                timestamps[i] = next;
            }
        }
    }

    /**
     * @notice Internal function to handle incoming messages and read responses.
     * @dev Filters messages based on `srcEid` to determine the type of incoming data.
     * @param _origin The origin information containing the source Endpoint ID (`srcEid`).
     * @param _guid The unique identifier for the received message.
     * @param _message The encoded message data.
     * @param _executor The executor address.
     * @param _extraData Additional data.
     */
    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) internal virtual override {
        /**
         * @dev The `srcEid` (source Endpoint ID) is used to determine the type of incoming message.
         * - If `srcEid` is greater than READ_CHANNEL_EID_THRESHOLD (4294965694),
         *   it corresponds to arbitrary channel IDs for lzRead responses.
         * - All other `srcEid` values correspond to standard LayerZero messages.
         */
        if (_origin.srcEid > LZ_READ_CHANNEL_EID_THRESHOLD) {
            // Handle lzRead responses from arbitrary channels.
            _readLzReceive(_origin, _guid, _message, _executor, _extraData);
        } else {
            // Handle standard LayerZero messages.
            revert("Unsupported message");
        }
    }

    /**
     * @notice Internal function to handle lzRead responses.
     * @dev _origin The origin information (unused in this implementation).
     * @dev _guid The unique identifier for the received message
     * @param _message The encoded message data.
     * @dev _executor The executor address (unused in this implementation).
     * @dev _extraData Additional data (unused in this implementation).
     */
    function _readLzReceive(
        Origin calldata /* _origin */,
        bytes32 _guid,
        bytes calldata _message,
        address /* _executor */,
        bytes calldata /* _extraData */
    ) internal virtual {
        lastFeeRateUpdateTimestamp = block.timestamp; //TODO Here it would be better to use timestamp of last reading
        lastFeeRate = abi.decode(_message, (uint256)); // Decoding what was encoded in `lzReduce()`
    }

    function _encodeReadStatDataCall(uint64[] memory timestamps) private view returns (bytes memory) {
        require(timestamps.length > 1, "need at least 2 timestamps");
        require(timestamps[timestamps.length - 1] <= uint64(block.timestamp), "timestamp in future");
        require(timestamps[0] <= timestamps[timestamps.length - 1], "wrong timestamp order");

        bytes memory readCalldata = abi.encodeWithSelector(this.readStatData.selector);

        EVMCallRequestV1[] memory requests = new EVMCallRequestV1[](timestamps.length);
        for (uint16 i; i < requests.length; i++) {
            requests[i] = EVMCallRequestV1({
                appRequestLabel: i,
                targetEid: _eid,
                isBlockNum: false,
                blockNumOrTimestamp: timestamps[i],
                confirmations: _confirmations,
                to: address(this), // We are reading form our own contract
                callData: readCalldata
            });
        }

        EVMCallComputeV1 memory compute = EVMCallComputeV1({
            computeSetting: 1, // lzReduce() only
            targetEid: _eid,
            isBlockNum: false,
            blockNumOrTimestamp: uint64(block.timestamp),
            confirmations: _confirmations,
            to: address(this) // Compute executed in this contract
        });

        return ReadCodecV1.encode(OAPP_READ_APP_LABEL, requests, compute);
    }

    function readStatData() public view returns (StatData memory stat) {
        stat.liquidity0 = liquidity0;
        stat.liquidity1 = liquidity1;
        (uint256 fee0, uint256 fee1) = _poolFees();
        stat.fee0 = fee0;
        stat.fee1 = fee1;
    }

    //function lzMap(bytes calldata _request, bytes calldata _response) external view returns (bytes memory){}

    function lzReduce(bytes calldata _cmd, bytes[] calldata _responses) external view returns (bytes memory) {
        require(_responses.length > 1, "not enough data");
        StatData memory psdStart = abi.decode(_responses[0], (StatData));
        StatData memory psdEnd = abi.decode(_responses[_responses.length], (StatData));
        uint256 sumMidLiquidity;
        if (_responses.length > 2)
            for (uint256 i; i < _responses.length; i++) {
                StatData memory psd = abi.decode(_responses[i], (StatData));
                sumMidLiquidity += psd.liquidity0;
            }
        uint256 averageLiquidity = uint128((sumMidLiquidity + psdStart.liquidity0 + psdEnd.liquidity0) / _responses.length);
        uint256 feeDelta0 = psdEnd.fee0 - psdStart.fee0;
        //uint256 feeDelta1 = psdEnd.fee0 - psdStart.fee0;
        // TODO make correct calculation
        uint256 feeRate = (1e18 * feeDelta0) / averageLiquidity;
        return abi.encode(feeRate);
    }
}
