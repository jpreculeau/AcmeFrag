#!/bin/bash
################################################################################
# SCRIPT DE MIGRATION - ACMEFRAG REFACTORISATION
# Automatise le remplacement des anciens fichiers par les nouveaux
# Usage: ./migrate_acmefrag.sh
#
# Licence / License: GNU General Public License v3
# COMMERCIAL USE REQUIRES PAID LICENSE
# Copyright (C) 2026 [Jean-Philippe Reculeau]
# See LICENSE file for full details
################################################################################

set -euo pipefail
IFS=$'\n\t'

####################################
# CONFIGURATION
####################################

BACKUP_SUFFIX=".bak"
NEW_SUFFIX=".new"
MIGRATION_LOG="migration_$(date +%Y%m%d_%H%M%S).log"

# Fichiers à migrer
declare -a FILES_TO_MIGRATE=(
    "config.sh"
    "AcmeFrag.sh"
    "defrag_functions.sh"
    "scan_functions.sh"
    "security_checks.sh"
    "display_functions.sh"
    "maintenance_functions.sh"
)

####################################
# FONCTIONS UTILITAIRES
####################################

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$MIGRATION_LOG"
}

error() {
    echo "❌ ERREUR: $*" | tee -a "$MIGRATION_LOG" >&2
}

success() {
    echo "✅ $*" | tee -a "$MIGRATION_LOG"
}

####################################
# VÉRIFICATIONS PRÉALABLES
####################################

verify_new_files_exist() {
    log "🔍 Vérification de l'existence des nouveaux fichiers..."
    
    for file in "${FILES_TO_MIGRATE[@]}"; do
        local new_file="${file}${NEW_SUFFIX}"
        if [ ! -f "$new_file" ]; then
            error "Le fichier $new_file est manquant."
            return 1
        fi
    done
    
    success "Tous les fichiers .new sont présents."
    return 0
}

check_bash_compatibility() {
    log "🔍 Vérification de la compatibilité Bash..."
    
    # Vérifier que bash >= 4.0 (pour ${var:0:N})
    if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
        error "Bash 4.0 ou supérieur est requis (vous avez ${BASH_VERSION})."
        return 1
    fi
    
    success "Bash ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]} détecté."
    return 0
}

check_permissions() {
    log "🔍 Vérification des permissions..."
    
    if [ ! -w . ]; then
        error "Vous n'avez pas les droits d'écriture dans le répertoire courant."
        return 1
    fi
    
    success "Permissions d'écriture OK."
    return 0
}

####################################
# MIGRATION
####################################

backup_old_files() {
    log "💾 Sauvegarde des anciens fichiers..."
    
    for file in "${FILES_TO_MIGRATE[@]}"; do
        if [ -f "$file" ]; then
            local backup_file="${file}${BACKUP_SUFFIX}"
            
            # Vérifier si une sauvegarde existe déjà
            if [ -f "$backup_file" ]; then
                log "   ⚠️  Sauvegarde existante: $backup_file (conservée)"
            else
                if cp "$file" "$backup_file"; then
                    log "   💾 $file → $backup_file"
                else
                    error "Impossible de sauvegarder $file."
                    return 1
                fi
            fi
        else
            log "   ℹ️  $file n'existe pas (pas besoin de sauvegarde)"
        fi
    done
    
    success "Sauvegarde effectuée."
    return 0
}

replace_files() {
    log "🔄 Remplacement des anciens fichiers..."
    
    for file in "${FILES_TO_MIGRATE[@]}"; do
        local new_file="${file}${NEW_SUFFIX}"
        
        if [ ! -f "$new_file" ]; then
            error "Le fichier $new_file est manquant."
            return 1
        fi
        
        # Supprimer l'ancien fichier
        if [ -f "$file" ]; then
            if rm "$file"; then
                log "   🗑️  Suppression: $file"
            else
                error "Impossible de supprimer $file."
                return 1
            fi
        fi
        
        # Renommer le nouveau fichier
        if mv "$new_file" "$file"; then
            log "   ✅ $new_file → $file"
        else
            error "Impossible de renommer $new_file."
            return 1
        fi
    done
    
    success "Remplacement effectué."
    return 0
}

set_permissions() {
    log "🔐 Configuration des permissions..."
    
    for file in "${FILES_TO_MIGRATE[@]}"; do
        if [ -f "$file" ]; then
            if chmod +x "$file"; then
                log "   📝 $file → exécutable"
            else
                error "Impossible de rendre $file exécutable."
                return 1
            fi
        fi
    done
    
    success "Permissions configurées."
    return 0
}

####################################
# VÉRIFICATION POST-MIGRATION
####################################

test_import_modules() {
    log "🧪 Test d'import des modules..."
    
    # Source config pour avoir les variables
    if ! source ./config.sh 2>/dev/null; then
        error "Impossible d'importer config.sh."
        return 1
    fi
    
    log "   ✅ config.sh importable"
    
    # Tester quelques imports critique
    for module in "security_checks.sh" "scan_functions.sh" "defrag_functions.sh"; do
        if ! source "./$module" 2>/dev/null; then
            error "Impossible d'importer $module."
            return 1
        fi
        log "   ✅ $module importable"
    done
    
    success "Tous les modules sont importables."
    return 0
}

test_main_script() {
    log "🧪 Test du script principal..."
    
    # Vérifier le shebang et la syntaxe
    if ! bash -n ./AcmeFrag.sh 2>&1 | grep -v "^$"; then
        success "Vérification syntaxe: OK"
    else
        error "La syntaxe du script est incorrecte."
        return 1
    fi
    
    return 0
}

####################################
# RAPPORT FINAL
####################################

display_summary() {
    log ""
    log "╔════════════════════════════════════════════════════════════════╗"
    log "║       RÉSUMÉ DE LA MIGRATION - ACMEFRAG REFACTORISATION      ║"
    log "╚════════════════════════════════════════════════════════════════╝"
    log ""
    log "📁  Fichiers migrés:"
    for file in "${FILES_TO_MIGRATE[@]}"; do
        log "   ✅ $file"
    done
    log ""
    log "💾 Fichiers de sauvegarde: *.bak (dans le répertoire courant)"
    log ""
    log "📋 Journal complet: $MIGRATION_LOG"
    log ""
    log "🚀 Prochaines étapes:"
    log "   1. Test : ./AcmeFrag.sh [/chemin/des] --auto"
    log "   2. Suppression des fichiers .bak si tout fonctionne"
    log ""
}

rollback_if_needed() {
    local should_rollback="$1"
    
    if [ "$should_rollback" == "yes" ]; then
        error "Rollback en cours..."
        
        for file in "${FILES_TO_MIGRATE[@]}"; do
            local backup_file="${file}${BACKUP_SUFFIX}"
            if [ -f "$backup_file" ]; then
                cp "$backup_file" "$file"
                log "   ↩️  Restauration: $file"
            fi
        done
        
        error "Rollback effectué. Les anciens fichiers ont été restaurés."
        return 1
    fi
    
    return 0
}

####################################
# POINT D'ENTRÉE PRINCIPAL
####################################

main() {
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║       MIGRATION - ACMEFRAG REFACTORISATION                   ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "⚠️  CE SCRIPT VA MODIFIER VOS FICHIERS BASH"
    echo ""
    echo "🛡️  Vos anciens fichiers seront sauvegardés avec l'extension .bak"
    echo ""
    
    read -p "Êtes-vous sûr de vouloir continuer? (o/N) : " -r confirmation
    echo ""
    
    if [[ ! "$confirmation" =~ ^[oO]$ ]]; then
        log "Migration annulée par l'utilisateur."
        exit 0
    fi
    
    log "Démarrage de la migration..."
    echo ""
    
    # Étape 1: Vérifications
    verify_new_files_exist || exit 1
    check_bash_compatibility || exit 1
    check_permissions || exit 1
    echo ""
    
    # Étape 2: Sauvegarde
    backup_old_files || exit 1
    echo ""
    
    # Étape 3: Remplacement
    replace_files || {
        error "La migration a échoué. Rollback..."
        rollback_if_needed "yes"
        exit 1
    }
    echo ""
    
    # Étape 4: Permissions
    set_permissions || {
        error "Configuration des permissions échouée."
        rollback_if_needed "yes"
        exit 1
    }
    echo ""
    
    # Étape 5: Vérifications post-migration
    test_import_modules || {
        error "Les modules ne sont pas importables."
        rollback_if_needed "yes"
        exit 1
    }
    echo ""
    
    test_main_script || {
        error "Le script principal a des erreurs de syntaxe."
        rollback_if_needed "yes"
        exit 1
    }
    echo ""
    
    # Étape 6: Rapport
    display_summary
    
    success "✨ MIGRATION RÉUSSIE! ✨"
    log ""
    log "Vous pouvez maintenant utiliser AcmeFrag.sh refactorisé."
    log "Les fichiers .bak peuvent être supprimés après vérification."
}

# Exécuter le script principal
main "$@"
