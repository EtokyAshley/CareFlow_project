/* =====================================================================
   CareFlow - 04_donnees_test.sql  (version 2 : UN SEUL etablissement)
   Donnees FICTIVES pour tester (aucune vraie donnee de patient).
   A executer une fois, apres 01, 02 et 03. Protege contre une double execution.
   Mots de passe : 'A_REMPLACER' n'est PAS un hash valide, ces comptes ne
   servent qu'aux tests SQL (l'application creera ses vrais comptes).
   Fichier volontairement sans accents (compatibilite SSMS).
   ===================================================================== */
SET NOCOUNT ON;

IF EXISTS (SELECT 1 FROM dbo.ParametreEtablissement)
BEGIN
    PRINT 'Des donnees existent deja : rien n''a ete insere.';
END
ELSE
BEGIN
    DECLARE @Now DATETIME2(0) = SYSUTCDATETIME();
    DECLARE @Spec1 INT, @Spec2 INT, @Prat1 INT, @Prat2 INT;
    DECLARE @P1 INT, @P2 INT, @P3 INT, @P4 INT;
    DECLARE @La1 INT, @La2 INT, @La3 INT, @La4 INT;
    DECLARE @Demain DATETIME2(0) = DATEADD(DAY, 1, CAST(CAST(@Now AS DATE) AS DATETIME2(0)));   -- demain 00:00 UTC

    -- L'etablissement unique : identite + regles (a faire valider par l'etablissement avant tout pilote)
    INSERT INTO dbo.ParametreEtablissement (NomEtablissement, Ville, Region, DelaiAcceptationMinutes, DelaiMinAvantCreneauMinutes, ValideParEtablissement, DateValidationUtc)
    VALUES (N'Centre de sante pilote (TEST)', N'Yaounde', N'Centre', 30, 60, 0, NULL);

    INSERT INTO dbo.Specialite (Nom) VALUES (N'Medecine generale');
    SET @Spec1 = SCOPE_IDENTITY();
    INSERT INTO dbo.Specialite (Nom) VALUES (N'Pediatrie');
    SET @Spec2 = SCOPE_IDENTITY();

    INSERT INTO dbo.Praticien (SpecialiteId, Nom) VALUES (@Spec1, N'Dr Test Generaliste');
    SET @Prat1 = SCOPE_IDENTITY();
    INSERT INTO dbo.Praticien (SpecialiteId, Nom) VALUES (@Spec2, N'Dr Test Pediatre');
    SET @Prat2 = SCOPE_IDENTITY();

    -- Personnel et administrateur de test
    INSERT INTO dbo.Utilisateur (Nom, Email, MotDePasseHash, Role, PraticienId)
    VALUES (N'Secretariat Test', N'secretariat@test.local', N'A_REMPLACER', 'PraticienSecretariat', @Prat1);
    INSERT INTO dbo.Utilisateur (Nom, Email, MotDePasseHash, Role)
    VALUES (N'Admin Test', N'admin@test.local', N'A_REMPLACER', 'Administrateur');

    -- Patients fictifs
    INSERT INTO dbo.Utilisateur (Nom, Email, MotDePasseHash, Role, Ville, Region) VALUES (N'Patient Test 1', N'patient1@test.local', N'A_REMPLACER', 'Patient', N'Yaounde', N'Centre');
    SET @P1 = SCOPE_IDENTITY();
    INSERT INTO dbo.Utilisateur (Nom, Email, MotDePasseHash, Role, Ville, Region) VALUES (N'Patient Test 2', N'patient2@test.local', N'A_REMPLACER', 'Patient', N'Yaounde', N'Centre');
    SET @P2 = SCOPE_IDENTITY();
    INSERT INTO dbo.Utilisateur (Nom, Email, MotDePasseHash, Role, Ville, Region) VALUES (N'Patient Test 3', N'patient3@test.local', N'A_REMPLACER', 'Patient', N'Douala', N'Littoral');
    SET @P3 = SCOPE_IDENTITY();
    INSERT INTO dbo.Utilisateur (Nom, Email, MotDePasseHash, Role, Ville, Region) VALUES (N'Patient Test 4', N'patient4@test.local', N'A_REMPLACER', 'Patient', N'Yaounde', N'Centre');
    SET @P4 = SCOPE_IDENTITY();

    -- 3 creneaux de demain avec le generaliste : 09:00, 10:00, 11:00 heure locale (= 08:00, 09:00, 10:00 UTC)
    INSERT INTO dbo.Creneau (PraticienId, DebutUtc, FinUtc)
    VALUES (@Prat1, DATEADD(HOUR, 8, @Demain),  DATEADD(MINUTE, 510, @Demain)),
           (@Prat1, DATEADD(HOUR, 9, @Demain),  DATEADD(MINUTE, 570, @Demain)),
           (@Prat1, DATEADD(HOUR, 10, @Demain), DATEADD(MINUTE, 630, @Demain));

    -- Liste d'attente en medecine generale
    -- P1 : tres ancien, priorite 2  (il annulera : il doit etre EXCLU de l'offre)
    INSERT INTO dbo.ListeAttente (PatientId, SpecialiteId, Ville, Region, Priorite, DateInscriptionUtc)
    VALUES (@P1, @Spec1, N'Yaounde', N'Centre', 2, DATEADD(DAY, -60, @Now));
    SET @La1 = SCOPE_IDENTITY();
    -- P2 : priorite 2, meme ville  -> score attendu 46 (premier candidat)
    INSERT INTO dbo.ListeAttente (PatientId, SpecialiteId, Ville, Region, Priorite, DateInscriptionUtc)
    VALUES (@P2, @Spec1, N'Yaounde', N'Centre', 2, DATEADD(DAY, -20, @Now));
    SET @La2 = SCOPE_IDENTITY();
    -- P3 : priorite 0, autre ville/region -> score attendu 40 (deuxieme candidat)
    INSERT INTO dbo.ListeAttente (PatientId, SpecialiteId, Ville, Region, Priorite, DateInscriptionUtc)
    VALUES (@P3, @Spec1, N'Douala', N'Littoral', 0, DATEADD(DAY, -40, @Now));
    SET @La3 = SCOPE_IDENTITY();
    -- P4 : disponible seulement 14h-16h -> hors disponibilites, ne doit JAMAIS etre sollicite pour 9h
    INSERT INTO dbo.ListeAttente (PatientId, SpecialiteId, Ville, Region, Priorite, DateInscriptionUtc)
    VALUES (@P4, @Spec1, N'Yaounde', N'Centre', 2, DATEADD(DAY, -10, @Now));
    SET @La4 = SCOPE_IDENTITY();

    -- Disponibilites (heure locale) : P1, P2, P3 tous les jours 08h-17h ; P4 tous les jours 14h-16h
    INSERT INTO dbo.DisponibiliteAttente (ListeAttenteId, JourSemaine, HeureDebut, HeureFin)
    SELECT la.Id, j.n, '08:00', '17:00'
    FROM (VALUES (@La1), (@La2), (@La3)) AS la(Id)
    CROSS JOIN (VALUES (1), (2), (3), (4), (5), (6), (7)) AS j(n);

    INSERT INTO dbo.DisponibiliteAttente (ListeAttenteId, JourSemaine, HeureDebut, HeureFin)
    SELECT @La4, j.n, '14:00', '16:00'
    FROM (VALUES (1), (2), (3), (4), (5), (6), (7)) AS j(n);

    PRINT 'Donnees de test inserees.';
END
GO
