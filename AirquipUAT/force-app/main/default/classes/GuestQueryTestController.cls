public without sharing class GuestQueryTestController {
    
    public Integer vendorCount { get; set; }
    public String errorMessage { get; set; }

    public GuestQueryTestController() {
        try {
            // Simply trying to count the Vendor records
            vendorCount = [SELECT count() FROM Vendor__c];
        } catch (Exception e) {
            // If it fails, capture the exact error message
            errorMessage = e.getMessage();
        }
    }
}