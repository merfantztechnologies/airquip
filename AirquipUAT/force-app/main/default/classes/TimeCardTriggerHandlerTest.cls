@IsTest
public class TimeCardTriggerHandlerTest {

    @IsTest
    static void testTimeCardHandler_AllScenarios() {

        /* ===============================
           CREATE ACCOUNT
        =============================== */
        Account acc = new Account(Name = 'Test Customer');
        insert acc;

        /* ===============================
           CREATE CONTACT (REQUIRED)
        =============================== */
        Contact con = new Contact(
            LastName = 'Test Contact',
            AccountId = acc.Id,
            Email = 'test@example.com' // ✅ REQUIRED for Flow
        );
        insert con;

        /* ===============================
           CREATE JOBS
        =============================== */
        fax__Job__c job1 = new fax__Job__c(
            fax__Customer__c = acc.Id,
            fax__Contact__c = con.Id, // ✅ Required for validation
            fax__Status__c = 'Queued',
            fax__Visit_Type__c = 'Service',
            fax__Urgency__c = 'NORMAL',
            fax__Planned_Visit_Date_Time__c = Datetime.now().addDays(1)
        );

        fax__Job__c job2 = new fax__Job__c(
            fax__Customer__c = acc.Id,
            fax__Contact__c = con.Id, // ✅ Required
            fax__Status__c = 'Queued',
            fax__Visit_Type__c = 'Service',
            fax__Urgency__c = 'NORMAL',
            fax__Planned_Visit_Date_Time__c = Datetime.now().addDays(2)
        );

        insert new List<fax__Job__c>{ job1, job2 };

        Test.startTest();

        /* ===============================
           INSERT TIMECARDS
        =============================== */
        fax__Time_Card__c tc1 = new fax__Time_Card__c(
            fax__Job2__c = job1.Id,
            fax__Hours__c = 5,
            fax__Time_for__c = 'Job'
        );

        fax__Time_Card__c tc2 = new fax__Time_Card__c(
            fax__Job2__c = job1.Id,
            fax__Hours__c = 3,
            fax__Time_for__c = 'Travel'
        );

        insert new List<fax__Time_Card__c>{ tc1, tc2 };

        Test.stopTest();

        /* ===============================
           VERIFY AFTER INSERT
        =============================== */
        job1 = [
            SELECT Labor_Time_Hrs__c, Travel_Time_Hrs__c
            FROM fax__Job__c WHERE Id = :job1.Id
        ];

        System.assertEquals(5, job1.Labor_Time_Hrs__c);
        System.assertEquals(3, job1.Travel_Time_Hrs__c);

        /* ===============================
           UPDATE HOURS
        =============================== */
        tc1.fax__Hours__c = 8;
        update tc1;

        job1 = [
            SELECT Labor_Time_Hrs__c, Travel_Time_Hrs__c
            FROM fax__Job__c WHERE Id = :job1.Id
        ];

        System.assertEquals(8, job1.Labor_Time_Hrs__c);
        System.assertEquals(3, job1.Travel_Time_Hrs__c);

        /* ===============================
           CHANGE TYPE (Job → Travel)
        =============================== */
        tc1.fax__Time_for__c = 'Travel';
        update tc1;

        job1 = [
            SELECT Labor_Time_Hrs__c, Travel_Time_Hrs__c
            FROM fax__Job__c WHERE Id = :job1.Id
        ];

        System.assertEquals(0, job1.Labor_Time_Hrs__c);
        System.assertEquals(11, job1.Travel_Time_Hrs__c);

        /* ===============================
           CHANGE JOB LOOKUP
        =============================== */
        tc1.fax__Job2__c = job2.Id;
        update tc1;

        job1 = [
            SELECT Labor_Time_Hrs__c, Travel_Time_Hrs__c
            FROM fax__Job__c WHERE Id = :job1.Id
        ];

        job2 = [
            SELECT Labor_Time_Hrs__c, Travel_Time_Hrs__c
            FROM fax__Job__c WHERE Id = :job2.Id
        ];

        System.assertEquals(0, job1.Labor_Time_Hrs__c);
        System.assertEquals(3, job1.Travel_Time_Hrs__c);

        System.assertEquals(0, job2.Labor_Time_Hrs__c);
        System.assertEquals(8, job2.Travel_Time_Hrs__c);

        /* ===============================
           DELETE TIMECARD
        =============================== */
        delete tc2;

        job1 = [
            SELECT Labor_Time_Hrs__c, Travel_Time_Hrs__c
            FROM fax__Job__c WHERE Id = :job1.Id
        ];

        System.assertEquals(0, job1.Labor_Time_Hrs__c);
        System.assertEquals(0, job1.Travel_Time_Hrs__c);

        /* ===============================
           UNDELETE TIMECARD
        =============================== */
        undelete tc2;

        job1 = [
            SELECT Labor_Time_Hrs__c, Travel_Time_Hrs__c
            FROM fax__Job__c WHERE Id = :job1.Id
        ];

        System.assertEquals(0, job1.Labor_Time_Hrs__c);
        System.assertEquals(3, job1.Travel_Time_Hrs__c);
    }
}