/**
 * SMSTemplateService
 * Loads SMS templates from SMS_Template__mdt using DeveloperName as key.
 *
 * Custom Metadata: SMS_Template__mdt
 *   Active__c        (Checkbox)   — Only active templates fire
 *   Message_Body__c  (Long Text)  — Message with {Placeholder} tokens
 */
public class SMSTemplateService {

    // ─── Template Name Constants ──────────────────────────────────────────
    // Use these in handler classes instead of hardcoded strings

    // Row 4 — Technician Assigned → Customer
    public static final String TECHNICIAN_ASSIGNED   = 'Technician_Assigned';

    // Row 5 — Emergency Job → Technician
    public static final String EMERGENCY_JOB         = 'Emergency_Job';

    // Row 6 — Technician On Site → Customer
    public static final String TECHNICIAN_ON_SITE    = 'Technician_On_Site';

    // Row 7 — Part Request Created → Technician
    public static final String PART_REQUEST_CREATED  = 'Part_Request_Created';

    // Row 8 — Part Request Received → Technician
    public static final String PART_REQUEST_APPROVED = 'Part_Request_Approved';

    // Row 9 — Low Stock Alert → Inventory Manager
    public static final String LOW_STOCK_ALERT       = 'Low_Stock_Alert';

    // Row 10 — Job Completed → Customer
    public static final String JOB_COMPLETED         = 'Job_Completed';

    // Row 11 — Invoice Generated → Customer
    public static final String INVOICE_GENERATED     = 'Invoice_Generated';

    // Row 12 — Contract Expiry 30 Days → Customer
    public static final String CONTRACT_EXPIRY_30    = 'Contract_Expiry_30';

    // Row 13 — Contract Expiry 60 Days → Customer
    public static final String CONTRACT_EXPIRY_60    = 'Contract_Expiry_60';

    // Row 14 — Frequency Job Created → Customer
    public static final String FREQUENCY_JOB_CREATED = 'Frequency_Job_Created';

    // ─── Template Cache (per transaction) ────────────────────────────────
    @TestVisible
    private static Map<String, SMS_Template__mdt> templateCache;

    private static Map<String, SMS_Template__mdt> getTemplates() {
        if (templateCache == null) {
            templateCache = new Map<String, SMS_Template__mdt>();
            for (SMS_Template__mdt t : [
                SELECT DeveloperName, Active__c, Message_Body__c
                FROM   SMS_Template__mdt
                WHERE  Active__c = true
            ]) {
                templateCache.put(t.DeveloperName, t);
            }
        }
        return templateCache;
    }

    /**
     * Build SMS message for a given template name.
     * @param templateName  DeveloperName of SMS_Template__mdt record
     *                      Use constants e.g. SMSTemplateService.JOB_COMPLETED
     * @param placeholders  Map of token → value e.g. {'CustomerName' => 'John'}
     * @return              Resolved message or null if template missing/inactive
     */
    public static String build(String templateName, Map<String, String> placeholders) {
        SMS_Template__mdt template = getTemplates().get(templateName);

        if (template == null) {
            System.debug(LoggingLevel.WARN,
                '[SMSTemplateService] No active template: "' + templateName +
                '". Create SMS_Template__mdt record with DeveloperName = ' + templateName);
            return null;
        }

        String msg = template.Message_Body__c;
        if (String.isBlank(msg)) return null;

        if (placeholders != null) {
            for (String key : placeholders.keySet()) {
                String val = placeholders.get(key);
                msg = msg.replace('{' + key + '}', val != null ? val : '');
            }
        }
        return msg;
    }

    @TestVisible
    private static void clearCache() {
        templateCache = null;
    }
}