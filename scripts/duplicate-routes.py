#!/usr/bin/env python3
"""
Duplicate Routes Script
Reads a Kong deck YAML file and duplicates each route with -mtls suffix and adds mTLS header matching.
"""

import sys
import yaml
import copy
from pathlib import Path

def duplicate_routes(input_file, output_file=None):
    """
    Duplicate each route in the Kong configuration with mTLS header matching.

    Args:
        input_file: Path to the input YAML file
        output_file: Path to the output YAML file (defaults to input_file if not specified)
    """
    # Read the input file
    with open(input_file, 'r') as f:
        config = yaml.safe_load(f)

    if not config:
        print("Error: Empty or invalid YAML file")
        return

    # Check if services exist
    if 'services' not in config or not config['services']:
        print("No services found in the configuration")
        return

    # Process each service
    for service in config['services']:
        if 'routes' not in service or not service['routes']:
            continue

        original_routes = service['routes']
        duplicated_routes = []

        # Duplicate each route
        for route in original_routes:
            # Add tag for non-mTLS route
            if 'tags' not in route:
                route['tags'] = []
            route['tags'].append('non-mtls')

            # Keep the original route
            duplicated_routes.append(route)

            # Create a duplicate with modified name and mTLS header matching
            duplicate_route = copy.deepcopy(route)

            # Modify the name with -mtls suffix
            original_name = route.get('name', 'unnamed-route')
            duplicate_route['name'] = f"{original_name}-mtls"

            # Add header matching for mTLS certificate
            if 'headers' not in duplicate_route:
                duplicate_route['headers'] = {}

            duplicate_route['headers']['X-Amzn-Mtls-Clientcert-Issuer'] = ['~*']

            # Add tag for mTLS route
            duplicate_route['tags'] = ['mtls']

            print(f"  Duplicated route: {original_name} -> {duplicate_route['name']} (with mTLS header)")

            duplicated_routes.append(duplicate_route)

        # Replace routes with duplicated list
        service['routes'] = duplicated_routes
        print(f"Service '{service.get('name', 'unnamed')}': {len(original_routes)} routes -> {len(duplicated_routes)} routes")

    # Write output file
    output_path = output_file if output_file else input_file
    with open(output_path, 'w') as f:
        yaml.dump(config, f, default_flow_style=False, sort_keys=False, allow_unicode=True)

    print(f"\nOutput written to: {output_path}")


def main():
    if len(sys.argv) < 2:
        print("Usage: python duplicate-routes.py <input-file> [output-file]")
        print("Example: python duplicate-routes.py kong.yaml kong-duplicated.yaml")
        sys.exit(1)

    input_file = sys.argv[1]
    output_file = sys.argv[2] if len(sys.argv) > 2 else None

    if not Path(input_file).exists():
        print(f"Error: File not found: {input_file}")
        sys.exit(1)

    print(f"Processing: {input_file}")
    duplicate_routes(input_file, output_file)
    print("Done!")


if __name__ == "__main__":
    main()
