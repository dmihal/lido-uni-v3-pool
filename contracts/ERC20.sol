//SPDX-License-Identifier: MIT
pragma solidity 0.7.6;

import './uniswap-v3/libraries/LowGasSafeMath.sol';

/// @notice Modified from the Uniswap V2 ERC20 contract
///         Adds a built-in "pauser" role which can be used by inherited contracts.
///         Pauser is added to this contract in order to minimize SLOAD operations, by
///         packing the paused variable into the same sloat as the totalSupply variable
contract ERC20 {
    using LowGasSafeMath for uint;

    string public constant name = 'Lido stETH UniV3 Pool';
    string public constant symbol = 'LDOPL';
    uint8 public constant decimals = 18;

    // Variables are packed into a single storage slots
    bool public paused = false;
    uint248 public totalSupply;

    address pauser;

    mapping(address => uint) public balanceOf;
    mapping(address => mapping(address => uint)) public allowance;

    bytes32 public DOMAIN_SEPARATOR;
    bytes32 public constant PERMIT_TYPEHASH = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    mapping(address => uint) public nonces;

    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    event PauserTransferred(address previousPauser, address newPauser);
    event Paused();
    event Unpaused();

    constructor() {
        pauser = msg.sender;

        uint chainId;
        assembly {
            chainId := chainid()
        }
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
                keccak256(bytes(name)),
                keccak256(bytes('1')),
                chainId,
                address(this)
            )
        );
    }

    modifier notPaused {
        require(!paused);
        _;
    }

    function transferPauser(address newPauser) external {
        require(pauser == msg.sender);
        require(newPauser != address(0));
        emit PauserTransferred(pauser, newPauser);
        pauser = newPauser;
    }

    function togglePaused() external {
        require(pauser == msg.sender);
        bool _paused = paused;
        paused = !_paused;
        if (_paused) {
            emit Unpaused();
        } else {
            emit Paused();
        }
    }

    function _mint(address to, uint value) internal {
        totalSupply = uint248(uint(totalSupply).add(value));
        balanceOf[to] = balanceOf[to].add(value);
        emit Transfer(address(0), to, value);
    }

    function _burn(address from, uint value) internal {
        require(from != address(0));
        balanceOf[from] = balanceOf[from].sub(value);
        totalSupply = uint248(uint(totalSupply).sub(value));
        emit Transfer(from, address(0), value);
    }

    function _approve(address owner, address spender, uint value) private {
        require(spender != address(0));
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function _transfer(address from, address to, uint value) private {
        require(to != address(0));
        balanceOf[from] = balanceOf[from].sub(value);
        balanceOf[to] = balanceOf[to].add(value);
        emit Transfer(from, to, value);
    }

    function approve(address spender, uint value) external returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    /// @notice Non-standard function to avoid issues with ERC-20 approve
    function increaseAllowance(address spender, uint256 addedValue) external returns (bool) {
        _approve(msg.sender, spender, allowance[msg.sender][spender].add(addedValue));
        return true;
    }

    /// @notice Non-standard function to avoid issues with ERC-20 approve
    function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool) {
        _approve(msg.sender, spender, allowance[msg.sender][spender].sub(subtractedValue));
        return true;
    }

    function transfer(address to, uint value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint value) external returns (bool) {
        if (allowance[from][msg.sender] != uint(-1)) {
            allowance[from][msg.sender] = allowance[from][msg.sender].sub(value);
        }
        _transfer(from, to, value);
        return true;
    }

    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external {
        require(deadline >= block.timestamp, 'EXPIRED');
        bytes32 digest = keccak256(
            abi.encodePacked(
                '\x19\x01',
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
            )
        );
        address recoveredAddress = ecrecover(digest, v, r, s);
        require(recoveredAddress != address(0) && recoveredAddress == owner, 'INVALID_SIGNATURE');
        _approve(owner, spender, value);
    }

    function transferAndCall(address to, uint256 value, bytes calldata data) external returns (bool) {
        // Other implementations of ERC677 don't force the recipient to be a contract, but
        // we'll break from that standard to ensure the user doesn't send to the wrong address
        require(isContract(to));

        _transfer(msg.sender, to, value);

        // Some implementations of ERC677 receivers return a boolean, some don't return
        // anything. We'll support both using a low-level call, similar to TransferHelper
        bytes memory transferCalldata = abi.encodeWithSignature(
            'onTokenTransfer(address,uint256,bytes)',
            msg.sender,
            value,
            data
        );
        (bool success, bytes memory returnData) = to.call(transferCalldata);
        require(
            success && (returnData.length == 0 || abi.decode(returnData, (bool))),
            'onTokenTransfer failed'
        );

        return true;
    }

    function isContract(address _addr) internal view returns (bool) {
        uint256 size;
        assembly { size := extcodesize(_addr) }
        return size > 0;
    }
}
