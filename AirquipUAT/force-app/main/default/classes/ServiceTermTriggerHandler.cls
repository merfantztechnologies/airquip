/**
 * ServiceTermTriggerHandler
 * SMS ROW 12 — Contract expiring in 30 days → SMS Customer
 * SMS ROW 13 — Contract expiring in 60 days → SMS Customer
 *
 * NOTE: Row 14 (Frequency Job Created) has moved to JobTriggerHandler
 *       It fires on fax__Job__c INSERT when fax__Service_Plan__c is populated
 */
public class ServiceTermTriggerHandler {

    // ════════════════════════════════════════════════════════════════════════
    // ROW 12 & 13 — Daily Contract Expiry Reminders
    // Called by ServiceTermExpiryScheduler every day at 8AM
    // Schedule: System.schedule('Contract Expiry SMS', '0 0 8 * * ?',
    //                            new ServiceTermExpiryScheduler());
    //
    // Template Row 12: SMSTemplateService.CONTRACT_EXPIRY_30
    // Template Row 13: SMSTemplateService.CONTRACT_EXPIRY_60
    // Placeholders: {CustomerName} {PlanNo} {ExpiryDate}
    // ════════════════════════════════════════════════════════════════════════
    public static void sendContractExpiryReminders() {
        Date today = Date.today();
        Date in30  = today.addDays(30);
        Date in60  = today.addDays(60);

        // Find all active service terms expiring in exactly 30 or 60 days
        List<fax__Service_Term__c> expiring = [
            SELECT Id, Name, fax__End_Date__c,
                   fax__Site__c, fax__Site_Contact_Phone__c,
                   fax__Site__r.Name, fax__Site__r.Phone
            FROM   fax__Service_Term__c
            WHERE  fax__Status__c = 'Active'
            AND    (fax__End_Date__c = :in30 OR fax__End_Date__c = :in60)
        ];

        if (expiring.isEmpty()) {
            System.debug('[ServiceTermTriggerHandler] No contracts expiring in 30 or 60 days today.');
            return;
        }

        System.debug('[ServiceTermTriggerHandler] Found ' + expiring.size() + ' expiring contracts.');

        for (fax__Service_Term__c st : expiring) {

            // Phone: Account Phone → Site Contact Phone
            String phone = String.isNotBlank(st.fax__Site__r.Phone)
                ? st.fax__Site__r.Phone
                : st.fax__Site_Contact_Phone__c;

            if (String.isBlank(phone)) {
                System.debug('[ServiceTermTriggerHandler] No phone for plan: ' + st.Name + ' — skipping.');
                continue;
            }

            String customerName = st.fax__Site__r.Name != null ? st.fax__Site__r.Name : '';
            String expiryDate   = st.fax__End_Date__c != null
                                  ? st.fax__End_Date__c.format() : 'soon';

            // Determine Row 12 (30 days) or Row 13 (60 days)
            Integer daysLeft    = Date.today().daysBetween(st.fax__End_Date__c);
            String  templateKey = daysLeft <= 30
                ? SMSTemplateService.CONTRACT_EXPIRY_30
                : SMSTemplateService.CONTRACT_EXPIRY_60;

            System.debug('[ServiceTermTriggerHandler] Plan: ' + st.Name +
                ' | Days Left: ' + daysLeft + ' | Template: ' + templateKey);

            String msg = SMSTemplateService.build(
                templateKey,
                new Map<String, String>{
                    'CustomerName' => customerName,
                    'PlanNo'       => nvl(st.Name),
                    'ExpiryDate'   => expiryDate
                }
            );

            if (String.isNotBlank(msg)) {
                RingCentralSMSService.sendSMS(phone, msg);
            }
        }
    }

    private static String nvl(String val) {
        return String.isNotBlank(val) ? val : '';
    }
}