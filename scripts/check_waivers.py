#!/usr/bin/env python3
"""
Validate security waivers and generate .trivyignore file.

This script:
1. Validates that all waivers have required fields
2. Checks that waivers haven't expired
3. Generates .trivyignore with non-expired approved waivers
"""

import sys
import yaml
from datetime import datetime, timezone


def check_waivers(waivers_file):
    """
    Validate waivers and generate .trivyignore file.
    
    Args:
        waivers_file: Path to waivers.yaml file
    
    Returns:
        Exit code 0 on success, non-zero on failure
    """
    try:
        with open(waivers_file, 'r') as f:
            data = yaml.safe_load(f)
        
        if not data or 'waivers' not in data:
            print("✓ No waivers to process")
            # Create empty .trivyignore
            with open('.trivyignore', 'w') as f:
                pass
            return 0
        
        waivers = data.get('waivers', [])
        valid_waivers = []
        required_fields = ['id', 'expiry', 'reason']
        
        for idx, waiver in enumerate(waivers):
            if not isinstance(waiver, dict):
                print(f"Error: Waiver at index {idx} is not a dictionary")
                return 1
            
            # Check for required fields
            missing_fields = [field for field in required_fields if field not in waiver]
            if missing_fields:
                print(f"Error: Waiver '{waiver.get('id', f'at index {idx}')}' missing fields: {', '.join(missing_fields)}")
                return 1
            
            # Check expiry date
            try:
                expiry_str = waiver['expiry']
                # Parse ISO 8601 format
                if expiry_str.endswith('Z'):
                    expiry_date = datetime.fromisoformat(expiry_str.replace('Z', '+00:00'))
                else:
                    expiry_date = datetime.fromisoformat(expiry_str)
                
                # Make comparison timezone-aware
                now = datetime.now(timezone.utc)
                if expiry_date.tzinfo is None:
                    expiry_date = expiry_date.replace(tzinfo=timezone.utc)
                
                if expiry_date < now:
                    print(f"Error: Waiver '{waiver['id']}' has expired on {waiver['expiry']}")
                    return 1
                
                valid_waivers.append(waiver)
            except ValueError as e:
                print(f"Error: Invalid expiry date format in waiver '{waiver.get('id')}': {e}")
                return 1
        
        # Generate .trivyignore file
        with open('.trivyignore', 'w') as f:
            for waiver in valid_waivers:
                f.write(f"{waiver['id']}\n")
        
        print(f"✓ Validated {len(valid_waivers)} waivers")
        print("✓ Generated .trivyignore")
        return 0
        
    except FileNotFoundError:
        print(f"Error: Waivers file not found: {waivers_file}")
        return 1
    except yaml.YAMLError as e:
        print(f"Error: Invalid YAML in {waivers_file}: {e}")
        return 1
    except Exception as e:
        print(f"Error: {e}")
        return 1


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: python3 check_waivers.py <waivers_file>")
        sys.exit(1)
    sys.exit(check_waivers(sys.argv[1]))
