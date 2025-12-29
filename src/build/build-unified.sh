#!/bin/bash
# Unified Revanced Build Script
# Replaces: Revanced.sh, Revanced-Beta.sh, Revanced-Extended.sh, etc.
# Usage: ./build-unified.sh <variant> <app_name>
#   variant: revanced, revanced-beta, revanced-extended, etc. (from variants.conf)
#   app_name: youtube, instagram, spotify, etc. (from apps.conf display_name field)

set -e
source "$(dirname "$0")/utils.sh"

# Configuration files
VARIANTS_CONF="$(dirname "$0")/../config/variants.conf"
APPS_CONF="$(dirname "$0")/../config/apps.conf"

#################################################

# Parse variant configuration from variants.conf
# Sets global variables: VARIANT_NAME, PATCHES_REPO, PATCHES_OWNER, etc.
parse_variant_config() {
	local variant_id="$1"

	if [[ ! -f $VARIANTS_CONF ]]; then
		red_log "[-] Variants configuration file not found: $VARIANTS_CONF"
		exit 1
	fi

	while IFS='|' read -r vid name patches_repo patches_owner patches_tag cli_repo cli_owner cli_tag cli_mode workflow; do
		# Skip comments and empty lines
		[[ $vid =~ ^#.*$ ]] || [[ -z $vid ]] && continue

		if [[ $vid == "$variant_id" ]]; then
			export VARIANT_ID="$vid"
			export VARIANT_NAME="$name"
			export PATCHES_REPO="$patches_repo"
			export PATCHES_OWNER="$patches_owner"
			export PATCHES_TAG="$patches_tag"
			export CLI_REPO="$cli_repo"
			export CLI_OWNER="$cli_owner"
			export CLI_TAG="$cli_tag"
			export CLI_MODE="$cli_mode"
			export WORKFLOW_NAME="$workflow"
			green_log "[+] Loaded variant: $VARIANT_NAME"
			return 0
		fi
	done <"$VARIANTS_CONF"

	red_log "[-] Unknown variant: $variant_id"
	red_log "[-] Available variants:"
	grep -v '^#' "$VARIANTS_CONF" | grep -v '^$' | cut -d'|' -f1
	exit 1
}

# Get app configuration from apps.conf
# Returns: package_name|display_name|apkmirror_path|patch_key|download_source|architectures|options|dpi|extra_notes
get_app_config() {
	local app_name="$1"

	if [[ ! -f $APPS_CONF ]]; then
		red_log "[-] Apps configuration file not found: $APPS_CONF"
		exit 1
	fi

	# Find the app configuration line(s) matching the display_name
	local config_line=$(grep -v '^#' "$APPS_CONF" | grep -v '^$' | grep -E "^\S+\|$app_name\|" | head -n1)

	if [[ -z $config_line ]]; then
		red_log "[-] Unknown app: $app_name"
		red_log "[-] Available apps:"
		grep -v '^#' "$APPS_CONF" | grep -v '^$' | cut -d'|' -f2 | sort -u
		exit 1
	fi

	echo "$config_line"
}

# Download variant-specific requirements (patches + CLI)
download_variant_requirements() {
	green_log "[+] Downloading requirements for $VARIANT_NAME"
	green_log "[+]   Patches: $PATCHES_OWNER/$PATCHES_REPO ($PATCHES_TAG)"
	green_log "[+]   CLI: $CLI_OWNER/$CLI_REPO ($CLI_TAG)"

	dl_gh "$PATCHES_REPO" "$PATCHES_OWNER" "$PATCHES_TAG"
	dl_gh "$CLI_REPO" "$CLI_OWNER" "$CLI_TAG"
}

# Determine output suffix based on variant
get_variant_suffix() {
	case "$VARIANT_ID" in
	*-beta)
		echo "-beta"
		;;
	*)
		echo ""
		;;
	esac
}

#################################################
# App Build Function
#################################################

# Build an app based on configuration
# Args: $1 = app_name (from apps.conf)
build_app() {
	local app_name="$1"
	local suffix=$(get_variant_suffix)

	# Get app configuration
	local config=$(get_app_config "$app_name")
	IFS='|' read -r package_name display_name apkmirror_path patch_key download_source architectures options dpi extra_notes <<<"$config"

	green_log "[+] Building $display_name ($package_name)"
	green_log "[+]   Patch key: $patch_key"
	green_log "[+]   Architectures: $architectures"
	green_log "[+]   Source: $download_source"

	# Download the APK
	case "$download_source" in
	apkmirror)
		get_apk "$package_name" "${display_name}${suffix}" "$display_name" "$apkmirror_path" "$options" "$dpi"
		;;
	apkpure)
		get_apkpure "$package_name" "${display_name}${suffix}" "$display_name" "$options"
		;;
	uptodown)
		get_uptodown "$display_name" "${display_name}${suffix}"
		;;
	*)
		red_log "[-] Unknown download source: $download_source"
		exit 1
		;;
	esac

	# Verify APK signature if certificate is configured
	# (verify_apk_signature will skip if no certificate is configured)
	local apk_path="./download/${display_name}${suffix}"
	if [[ -f "${apk_path}.apkm" ]]; then
		verify_apk_signature "${apk_path}.apkm" "$package_name" || true
	elif [[ -f "${apk_path}.apk" ]]; then
		verify_apk_signature "${apk_path}.apk" "$package_name" || true
	fi

	# Handle special architecture cases
	if [[ $architectures == "lite" ]]; then
		# Lite build with minimal language/DPI
		process_lite_builds "${display_name}${suffix}" "$VARIANT_ID" "$patch_key" "$CLI_MODE"
	elif [[ $architectures == "all" ]]; then
		# Universal APK for all architectures
		get_patches_key "$patch_key"
		if [[ $options == "Bundle_extract" ]]; then
			split_editor "${display_name}${suffix}" "${display_name}${suffix}"
		fi
		patch "${display_name}${suffix}" "$VARIANT_ID" "$CLI_MODE"
	elif [[ -n $architectures ]]; then
		# Multiple architecture-specific builds
		if [[ $options == "Bundle_extract" ]]; then
			# For Bundle_extract, first process the full bundle
			get_patches_key "$patch_key"
			split_editor "${display_name}${suffix}" "${display_name}${suffix}"
			patch "${display_name}${suffix}" "$VARIANT_ID" "$CLI_MODE"

			# Then process individual architectures
			process_architectures "${display_name}${suffix}" "$VARIANT_ID" "$patch_key" "$CLI_MODE" "$architectures"
		else
			# For non-bundle, just process architectures
			process_architectures "${display_name}${suffix}" "$VARIANT_ID" "$patch_key" "$CLI_MODE" "$architectures"
		fi
	else
		# Single APK, no architecture splitting
		get_patches_key "$patch_key"
		patch "${display_name}${suffix}" "$VARIANT_ID" "$CLI_MODE"
	fi

	green_log "[+] ✓ Successfully built $display_name"
}

#################################################
# Main Entry Point
#################################################

# Usage check
if [[ $# -lt 2 ]]; then
	echo "Usage: $0 <variant> <app_name>"
	echo ""
	echo "Variants:"
	grep -v '^#' "$VARIANTS_CONF" | grep -v '^$' | awk -F'|' '{printf "  %-30s %s\n", $1, $2}'
	echo ""
	echo "Apps:"
	grep -v '^#' "$APPS_CONF" | grep -v '^$' | awk -F'|' '{printf "  %-30s %s\n", $2, $9}' | sort -u
	exit 1
fi

VARIANT="$1"
APP_NAME="$2"

# Parse variant configuration
parse_variant_config "$VARIANT"

# Download patches and CLI for this variant
download_variant_requirements

# Build the app
build_app "$APP_NAME"

green_log "[+] Build complete!"
