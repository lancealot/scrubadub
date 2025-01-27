
![alt_text](https://github.com/lancealot/scrubadub/blob/main/scrubadub.png?raw=true)

# Scrubadub

Scrubadub is a command-line tool that helps Ceph administrators optimize their cluster's scrub settings. It calculates recommended scrub parameters based on your cluster's OSD composition, PG distribution, and workload patterns.

## Why Scrubadub?

Ceph's default scrub settings are designed for small clusters. However, larger and more active clusters often fall behind on scrubs when using these defaults. Scrubadub helps you:

- Calculate optimal scrub parameters for your specific cluster
- Balance data integrity with cluster performance
- Prevent scrub operations from falling behind
- Minimize impact on cluster workloads

## Features

- Supports mixed OSD types (HDD/SSD/NVMe)
- Handles varying PG distributions
- Optimizes for different workload patterns:
  * Heavy Read
  * Heavy Write
  * Mixed Use
  * Archival
- Provides clear implementation commands
- Includes backup and rollback guidance

## Quick Start

1. Clone the repository:
```bash
git clone https://github.com/yourusername/scrubadub.git
cd scrubadub
```

2. Make the script executable:
```bash
chmod +x scrubadub.sh
```

3. Gather your cluster information:
```bash
# Get OSD tree showing device classes
ceph osd tree --format json-pretty

# Get PG distribution
ceph pg dump pools --format json-pretty

# Get current scrub settings
ceph config dump | grep -E 'scrub|osd_max_scrubs'
```

4. Run the script:
```bash
./scrubadub.sh
```

5. Follow the prompts to input your cluster's information.

## Documentation

- [Usage Guide](USAGE.md) - Detailed usage instructions and parameter explanations
- [Project Plan](projectplan.md) - Technical specifications and implementation details

## Requirements

- Bash shell (Linux, macOS, or Windows with WSL)
- No additional dependencies

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Support

If you encounter any issues or have questions, please file an issue on the GitHub repository.
