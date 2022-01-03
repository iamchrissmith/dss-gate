/* SPDX-License-Identifier: UNLICENSED */
pragma solidity ^0.8.0;

import "dss-interfaces.git/dss/VatAbstract.sol";
import "./common/math.sol";

// --- Gate 1 ---
// Gate 1 "Simple Gate" design:
//  * token approval style draw limit on vat.suck
//  * backup dai balance in case vat.suck fails
//  * access priority- try vat.suck first, backup balance second
//  * no hybrid draw at one time from both vat.suck and backup balance
//
// - DEPLOYMENT
//  * ideally, each gate contract should only be linked to a single integration
//  * authorized integration can then request a dai amount from gate contract with a "draw" call
// 
// - DRAW LIMIT
//  * a limit on the amount of dai that can an integration can draw with a vat.suck call
//  * simple gate uses an approved total amount, similar to a token approval
//  * integrations can access up to this dai amount in total
//
// - BACKUP BALANCE
//  * gate can hold a backup dai balance
//  * allows integrations to draw dai when calls to vat.suck fail for any reason
//
// - DRAW SOURCE SELECTION, ORDER
//  * this gate will not draw from both sources(vat.suck, backup dai balance) in a single draw call
//  * draw call forwarded to vat.suck first
//  * and then backup balance is tried when vat.suck fails due to draw limit or if gate is not authorized by vat
//  * unlike draw limits applied to a vat.suck call, no additional checks are done when backup balance is used as source for draw
//
// - DAI FORMAT
//  * integrates with dai balance on vat, which uses the dsmath rad number type- 45 decimal fixed-point number
//
// - MISCELLANEOUS
//  * does not execute vat.heal to ensure the dai draw amount from vat.suck is lower than the surplus buffer currently held in vow
//  * does not check whether vat is live at deployment time
//  * vat, gov, and vow addresses cannot be updated after deployment

contract Gate1 is DSMath {
    address gov; // maker protocol governance
    VatAbstract vat; // maker protocol vat
    address vow; // maker protocol vow

    mapping (address => bool) public integrations; // integrations access status

    // draw limit- total amount that can be drawn from vat.suck
    uint256 approvedTotal; // [rad] 

    // withdraw condition- timestamp after which backup dai balance withdrawal is allowed
    uint256 public withdrawAfter; // [timestamp]

    constructor(address gov_, address vat_, address vow_) {
        gov = gov_; // set governance address 
        vat = VatAbstract(vat_); // set vat address
        vow = vow_; // set vow address

        withdrawAfter = block.timestamp; // set withdrawAfter to now
        // governance should set withdrawAfter to a future timestamp after deployment 
        // and loading a backup balance in gate to give the integration a guarantee 
        // that the backup dai balance will not be prematurely withdrawn 
    }

    // --- Function Modifiers ---
    modifier onlyGov() {
        require(msg.sender == gov, "gov/not-authorized"); // only allow governance
        _;
    }

    modifier onlyIntegration() {
        require(integrations[msg.sender] == true, "integration/not-authorized"); // only allow approved integration
        _;
    }

    // --- Auth ---
    function relyIntegration(address integration_) external onlyGov { 
        require(integrations[integration_] = false, "integration/approved");
        integrations[integration_] = true; // permit integration access
    }

    function denyIntegration(address integration_) external onlyGov { 
        require(integrations[integration_] = true, "integration/not-approved");
        integrations[integration_] = false; // deny integration access
    }

    // --- UTILS ---
    // return dai balance amount
    function daiBalance() public view returns (uint256) {
        return vat.dai(address(this));
    }

    // transfer dai balance from gate to destination
    function transferDai(address dst_, uint256 amount_) internal {
        // check if sufficient dai balance is present
        require(amount_ <= daiBalance(), "gate/insufficient-dai-balance");

        vat.move(address(this), dst_, amount_); // transfer as vat dai balance
    }

    // return maximum draw amount possible
    // based on draw limit and backup balance
    // this gate design can only draw from one of these two sources in a single call
    // max draw amount returned does not account for conditions that could result in failure of the vat.suck call
    function maxDrawAmount() public view returns (uint256) {
        return max(approvedTotal, daiBalance());
    }

    // --- Draw Limits ---
    // allow governance to update draw limit
    function updateApprovedTotal(uint256 newTotal_) public onlyGov {
        approvedTotal = newTotal_; // update approved total amount
    }

    // internal function that performs a draw limit check and then calls vat.suck
    // returns true upon successful vat.suck call
    // else return false
    // does not revert when vat.suck fails to allow parent draw call
    // to determine best course of action, ex: try to use backup balance next
    // note: draw can still be successful even after accessSuck failure if sufficient backup balance is present
     // vat.suck can fail due to lack of authorization in vat, or after emergency shutdown
    function accessSuck(uint256 amount_) internal returns (bool) {
        // ensure approved total to access vat.suck is greater than draw amount requested
        bool drawLimitCheck = (approvedTotal >= amount_);

        if(drawLimitCheck) { // check passed
            // decrease approvedTotal by draw amount
            approvedTotal = subu(approvedTotal, amount_);

            // call suck to transfer dai from vat to this gate contract
            try vat.suck(address(vow), address(this), amount_) {
                // optional: can call vat.heal(amount_) here to ensure
                // surplus buffer has sufficient dai balance 
                
                // accessSuck success- successful vat.suck execution for requested amount
                return true;
            } catch {
                // accessSuck failure-  failed vat.suck call
                return false;
            }
        } else { // check failed
            // accessSuck failure- insufficient draw limit(approvedTotal)
            return false;
        }
    }

    // --- Draw Functions ---
    // draw implementation
    // draw can be successful even after vat.suck fails when backup balance held exceeds amount requested
    // draw will fail even if the combined balance from draw limit and backup balance adds up to the amount requested
    // this implementation can only draw dai from a single source between vat.suck and backup dai balance in a single draw call
    function _draw(address dst_, uint256 amount_) internal {
        accessSuck(amount_); // try drawing amount from vat.suck
        // return value from accessSuck ignored in this gate design
        
        // amount can still come from backup balance after accessSuck fails
        
        // transfer amount to the input destination address
        transferDai(dst_, amount_);
    }

    // draw function for integration to draw dai from gate
    function draw(uint256 amount_) external onlyIntegration {
        _draw(msg.sender, amount_);
    }

    // implements a function with the same signature as vat.suck for backwards compatibility
    function suck(address u, address v, uint256 rad) external onlyIntegration {
        u; // ignored
        // accessSuck already incorporartes the vow address as u according to the specification

        _draw(v, rad); // v (destination address)
    }

    // --- Backup Balance Withdraw Restrictions ---
    // withdrawal restrictions check
    // withdrawalConditionSatisfied() function returns true or false
    // allows or stops governance from withdrawing dai from the backup balance
    // note: function implements a standard interface with the amount_ input but value is not utilized here
    function withdrawalConditionSatisfied(uint256 amount_) internal returns (bool) {
        // restriction on withdrawal based on balance expiry date
        // not based on amount_ withdrawn in this gate design
        amount_; // ignored

        // governance can withdraw any amount of the backup balance once past withdrawAfter timestamp
        bool withdrawalAllowed = (block.timestamp >= withdrawAfter);

        return withdrawalAllowed;
    }
    
    // withdraw dai backup balance
    function withdrawDai(uint256 amount_) external onlyGov {
        require(withdrawalConditionSatisfied(amount_), "withdraw-condition-not-satisfied");
        transferDai(gov, amount_); // withdraw dai to governance address
    }

    /// Update withdrawAfter timestamp
    /// @dev restricted to be executed only by current governance
    /// @param newWithdrawAfter New timestamp
    /// @notice can only set withdrawAfter to a higher timestamp
    function updateWithdrawAfter(address newWithdrawAfter) public onlyGov {
        require(newWithdrawAfter > withdrawAfter, "withdrawAfter/value-lower");
        withdrawAfter = newWithdrawAfter;
    }

    // --- Vat Forwarders ---
    // gate can be setup as a one-stop access point to vat 
    // vat function forwarders allow an integration to call other vat functions
    // both public and restricted functions
    
    // heal forwarder 
    // access to heal can be used appropriately by an integration before drawing dai
    // for ex, to understand true state of surplus buffer
    function heal(uint rad) external {
        vat.heal(rad);
    }
}