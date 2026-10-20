/* =====================================================================
   CareFlow - 03_vues.sql  (version 3 : MULTI-ETABLISSEMENTS)
   Vues du tableau de bord (F8). Chaque vue renvoie UNE LIGNE PAR ETABLISSEMENT.
   Pour un tableau de bord d'etablissement : WHERE EtablissementId = @Id.
   Fichier volontairement sans accents (compatibilite SSMS).
   ===================================================================== */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* Taux d'occupation (creneaux non annules) */
CREATE OR ALTER VIEW dbo.vw_TauxOccupation
AS
SELECT  e.Id AS EtablissementId,
        e.Nom AS Etablissement,
        COUNT(c.Id) AS NbCreneaux,
        SUM(CASE WHEN c.Statut = 'Reserve' THEN 1 ELSE 0 END) AS NbReserves,
        CAST(100.0 * SUM(CASE WHEN c.Statut = 'Reserve' THEN 1 ELSE 0 END) / NULLIF(COUNT(c.Id), 0) AS DECIMAL(5,1)) AS TauxOccupationPourcent
FROM dbo.Etablissement AS e
LEFT JOIN dbo.Praticien AS p ON p.EtablissementId = e.Id
LEFT JOIN dbo.Creneau AS c ON c.PraticienId = p.Id AND c.Statut <> 'Annule'
GROUP BY e.Id, e.Nom;
GO

/* Creneaux liberes (annulations) et recuperes (de nouveau reserves) */
CREATE OR ALTER VIEW dbo.vw_CreneauxRecuperes
AS
SELECT  e.Id AS EtablissementId,
        e.Nom AS Etablissement,
        COUNT(DISTINCT c.Id) AS CreneauxLiberes,
        COUNT(DISTINCT CASE WHEN ra.Id IS NOT NULL THEN c.Id END) AS CreneauxRecuperes,
        CAST(100.0 * COUNT(DISTINCT CASE WHEN ra.Id IS NOT NULL THEN c.Id END) / NULLIF(COUNT(DISTINCT c.Id), 0) AS DECIMAL(5,1)) AS TauxRecuperationPourcent
FROM dbo.Etablissement AS e
LEFT JOIN dbo.Praticien AS p ON p.EtablissementId = e.Id
LEFT JOIN dbo.Creneau AS c ON c.PraticienId = p.Id
                          AND EXISTS (SELECT 1 FROM dbo.Reservation AS rc WHERE rc.CreneauId = c.Id AND rc.Statut = 'Annulee')
LEFT JOIN dbo.Reservation AS ra ON ra.CreneauId = c.Id AND ra.Statut = 'Active'
GROUP BY e.Id, e.Nom;
GO

/* Indicateur principal : delai moyen (en jours) entre la demande et le PREMIER rendez-vous du patient, par etablissement */
CREATE OR ALTER VIEW dbo.vw_DelaiPremierRdv
AS
WITH premiers AS (
    SELECT  p.EtablissementId, r.PatientId, r.DateDemandeUtc, c.DebutUtc,
            ROW_NUMBER() OVER (PARTITION BY p.EtablissementId, r.PatientId ORDER BY c.DebutUtc) AS Rang
    FROM dbo.Reservation AS r
    JOIN dbo.Creneau AS c ON c.Id = r.CreneauId
    JOIN dbo.Praticien AS p ON p.Id = c.PraticienId
    WHERE r.Statut = 'Active'
)
SELECT  e.Id AS EtablissementId,
        e.Nom AS Etablissement,
        COUNT(pr.PatientId) AS NbPatients,
        CAST(AVG(CAST(DATEDIFF(MINUTE, pr.DateDemandeUtc, pr.DebutUtc) AS FLOAT)) / 1440.0 AS DECIMAL(10,2)) AS DelaiMoyenJours
FROM dbo.Etablissement AS e
LEFT JOIN premiers AS pr ON pr.EtablissementId = e.Id AND pr.Rang = 1
GROUP BY e.Id, e.Nom;
GO

PRINT 'Vues CareFlow creees.';
GO
