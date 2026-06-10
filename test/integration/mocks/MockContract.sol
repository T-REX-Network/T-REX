pragma solidity 0.8.30;

contract MockContract {

    address _irRegistry;
    uint16 _investorCountry;
    address _compliance;

    function identityRegistry() public view returns (address) {
        if (_irRegistry != address(0)) {
            return _irRegistry;
        } else {
            return address(this);
        }
    }

    function investorCountry(address) public view returns (uint16) {
        return _investorCountry;
    }

    function setInvestorCountry(uint16 country) public {
        _investorCountry = country;
    }

    function setCompliance(address complianceAddress) public {
        _compliance = complianceAddress;
    }

    function compliance() public view returns (address) {
        return _compliance;
    }

}
