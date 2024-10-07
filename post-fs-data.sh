#!/system/bin/sh

# Redirect output and error logs to a file
exec > /data/local/tmp/CustomCACert.log 2>&1

# Enable debugging mode
set -x

# Set the module directory based on script location
MODDIR=${0%/*}

# Function to set SELinux context for a target directory based on the source
set_selinux_context() {
    local src_dir="$1"
    local target_dir="$2"

    # Check if SELinux is in Enforcing mode
    if [ "$(getenforce)" = "Enforcing" ]; then
        local default_context="u:object_r:system_file:s0"
        local src_context=$(ls -Zd "$src_dir" | awk '{print $1}')

        # Set SELinux context from source or fallback to default
        if [ -n "$src_context" ] && [ "$src_context" != "?" ]; then
            chcon -R "$src_context" "$target_dir" || echo "Failed to set SELinux context: $src_context"
        else
            chcon -R "$default_context" "$target_dir" || echo "Failed to set default SELinux context: $default_context"
        fi
    fi
}

# Function to clone and mount certificates
clone_and_mount_certs() {
    local temp_cert_dir="/data/local/tmp/sys-ca-copy"

    # Clear and recreate the temporary directory
    rm -rf "$temp_cert_dir"
    mkdir -p "$temp_cert_dir"

    # Mount tmpfs to the temporary certificate directory
    mount -t tmpfs tmpfs "$temp_cert_dir" || {
        echo "Failed to mount tmpfs to $temp_cert_dir"
        return 1
    }

    # Copy system and module certificates to the temp directory
    cp -f /apex/com.android.conscrypt/cacerts/* "$temp_cert_dir/" || echo "Failed to copy system certs"
    cp -f "${MODDIR}/system/etc/security/cacerts/"* "$temp_cert_dir/" || echo "Failed to copy module certs"

    # Set ownership and SELinux context for the certificates
    chown -R 0:0 "$temp_cert_dir"
    set_selinux_context /apex/com.android.conscrypt/cacerts "$temp_cert_dir"

    # Count the certificates and proceed if there are enough
    local cert_count
    cert_count=$(find "$temp_cert_dir" -type f | wc -l)
    if [ "$cert_count" -gt 10 ]; then
        # Bind mount the certificates to the system directory
        mount --bind "$temp_cert_dir" /apex/com.android.conscrypt/cacerts || {
            echo "Failed to bind mount certificates"
            return 1
        }

        # Bind mount the certificates in zygote processes
        for pid in 1 $(pgrep zygote) $(pgrep zygote64); do
            nsenter --mount=/proc/"$pid"/ns/mnt -- \
                mount --bind "$temp_cert_dir" /apex/com.android.conscrypt/cacerts || {
                echo "Failed to bind mount certificates in PID: $pid"
            }
        done
    else
        echo "Insufficient certificates to proceed with bind mount"
        return 1
    fi

    # Unmount and remove the temporary directory
    umount "$temp_cert_dir" || echo "Failed to unmount $temp_cert_dir"
    rmdir "$temp_cert_dir" || echo "Failed to remove $temp_cert_dir"
}

# Set ownership and SELinux context for the module certificates
chown -R 0:0 "${MODDIR}/system/etc/security/cacerts"
set_selinux_context /system/etc/security/cacerts "${MODDIR}/system/etc/security/cacerts"

# If the system certificate directory exists, clone and mount the certificates
if [ -d /apex/com.android.conscrypt/cacerts ]; then
    clone_and_mount_certs || {
        echo "Error during certificate cloning and mounting process"
        exit 1
    }
else
    echo "/apex/com.android.conscrypt/cacerts not found, cannot proceed"
    exit 1
fi
