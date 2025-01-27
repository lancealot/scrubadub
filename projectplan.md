# Scrubadub Project Plan

## Project Overview
Scrubadub is a command-line tool designed to help Ceph administrators optimize their cluster's scrub settings. The tool calculates recommended scrub parameters based on cluster composition and workload patterns.

## Technical Specifications

### Input Processing
1. OSD Information
   - Collects count of HDDs, SSDs, and NVMe devices
   - Validates inputs are non-negative integers
   - Ensures at least one OSD type exists
   - Calculates per-device and total performance metrics

2. Device Performance Characteristics
   - HDDs: 150 MB/s, 125 IOPS
   - SSDs: 475 MB/s, 70,000 IOPS
   - NVMe: 2,750 MB/s, 600,000 IOPS
   - Aggregates total cluster throughput and IOPS

3. PG Distribution
   - Collects PG counts per device type
   - Calculates PG-per-OSD ratios
   - Uses highest PG-per-OSD ratio for recommendations
   - Estimates total data to be scrubbed

4. Workload Profiling
   - Four distinct workload types
   - Each profile affects multiple parameters
   - Parameters tuned based on empirical guidelines
   - Includes time window configurations

### Calculation Logic

#### Performance Calculations
1. Per-Device Metrics
   ```bash
   device_throughput = count * base_throughput
   device_iops = count * base_iops
   ```

2. Total Cluster Performance
   ```bash
   total_throughput = sum(device_throughput)
   total_iops = sum(device_iops)
   ```

3. Scrub Time Estimation
   ```bash
   total_data = pg_count * avg_pg_size_gb * 1024  # Convert to MB
   time_seconds = total_data / total_throughput
   time_hours = time_seconds / 3600
   ```

#### Base Values
```bash
osd_scrub_min_interval = 86400  # 24 hours
osd_scrub_max_interval = 604800 # 7 days
osd_deep_scrub_interval = 604800 # 7 days
osd_max_scrubs = 1
osd_scrub_load_threshold = 0.5
osd_scrub_sleep = 0
osd_scrub_begin_hour = 1
osd_scrub_end_hour = 7
```

#### Adjustment Factors
1. PG Density Adjustments
   - High PG count (>200 PGs/OSD):
     * Increases max_scrubs to 3
     * Reduces load threshold to 0.4

2. Scrub Time Adjustments
   - >7 days estimated:
     * Increases max_scrubs by 2
     * Triggers warning
   - >3 days estimated:
     * Increases max_scrubs by 1
     * Issues notice

3. Workload-Based Adjustments
   - Heavy Read:
     * load_threshold = 0.3
     * scrub_sleep = 20
     * scrub_window = 1-6
   - Heavy Write:
     * load_threshold = 0.2
     * scrub_sleep = 30
     * min_interval = 172800 (48h)
     * scrub_window = 2-5
   - Mixed Use:
     * load_threshold = 0.4
     * scrub_sleep = 15
     * scrub_window = 1-7
   - Archival:
     * load_threshold = 0.6
     * scrub_sleep = 10
     * scrub_window = 0-23

### Architecture Decisions

1. Standalone Script
   - Single bash script for portability
   - No external dependencies
   - Cross-platform compatibility (Linux/Mac/WSL)
   - Performance metrics built into script

2. Input Validation
   - Strict number validation
   - Zero-value handling for absent device types
   - Clear error messages
   - Performance metric validation

3. Output Format
   - Color-coded sections
   - Clear command examples
   - Backup instructions
   - Implementation recommendations
   - Performance analysis section
   - Time estimates and warnings

4. Error Handling
   - Input validation with helpful messages
   - Division by zero protection
   - Workload type validation

### Performance Considerations

1. Calculation Efficiency
   - Simple arithmetic operations
   - No external process calls
   - Minimal memory usage
   - Optimized performance calculations

2. Scrub Time Management
   - Automatic adjustment of max_scrubs
   - Time window optimization
   - Prevention of scrub backlog
   - Balance between speed and impact

2. User Experience
   - Progressive input collection
   - Clear section headers
   - Formatted output

### Future Enhancements

1. Potential Features
   - Configuration file support
   - Historical setting tracking
   - Performance impact simulation
   - Integration with ceph command-line tools
   - Real-time performance monitoring
   - Adaptive time window adjustment

2. Improvements
   - Additional workload profiles
   - More granular PG distribution analysis
   - Machine learning for parameter optimization
   - Integration with monitoring systems
   - Dynamic performance baseline updates
   - Automated performance verification

## Development Workflow

1. Version Control
   - Git repository
   - Apache 2.0 license
   - Semantic versioning

2. Testing Strategy
   - Manual testing scenarios
   - Edge case validation
   - Cross-platform verification

3. Documentation
   - README.md: Project overview
   - USAGE.md: Detailed usage guide
   - projectplan.md: Technical documentation
   - In-code comments

## Implementation Notes

### Code Organization
```
scrubadub/
├── LICENSE (Apache 2.0)
├── README.md
├── USAGE.md
├── projectplan.md
├── .gitignore
└── scrubadub.sh
```

### Script Structure
1. Utility Functions
   - Print formatting
   - Input validation
   - Calculations

2. Main Flow
   - Information collection
   - Validation
   - Calculations
   - Recommendations

3. Output Sections
   - Current state
   - Analysis
   - Recommendations
   - Additional guidance

### Validation Rules
1. Input Constraints
   - Non-negative integers
   - At least one OSD type
   - Valid workload selection

2. Calculation Guards
   - Division by zero protection
   - Boundary checking
   - Type validation

### Parameter Relationships
- Higher PG counts → Higher max_scrubs
- Write workload → Higher sleep values
- Read workload → Lower load threshold
- Archival → Higher load threshold
