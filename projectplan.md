# Scrubadub Project Plan

## Project Overview
Scrubadub is a command-line tool designed to help Ceph administrators optimize their cluster's scrub settings. The tool calculates recommended scrub parameters based on cluster composition and workload patterns.

## Technical Specifications

### Input Processing
1. OSD Information
   - Collects count of HDDs, SSDs, and NVMe devices
   - Validates inputs are non-negative integers
   - Ensures at least one OSD type exists

2. PG Distribution
   - Collects PG counts per device type
   - Calculates PG-per-OSD ratios
   - Uses highest PG-per-OSD ratio for recommendations

3. Workload Profiling
   - Four distinct workload types
   - Each profile affects multiple parameters
   - Parameters tuned based on empirical guidelines

### Calculation Logic

#### Base Values
```bash
osd_scrub_min_interval = 86400  # 24 hours
osd_scrub_max_interval = 604800 # 7 days
osd_deep_scrub_interval = 604800 # 7 days
osd_max_scrubs = 1
osd_scrub_load_threshold = 0.5
osd_scrub_sleep = 0
```

#### Adjustment Factors
1. PG Density Adjustments
   - High PG count (>200 PGs/OSD):
     * Increases max_scrubs to 3
     * Reduces load threshold to 0.4

2. Workload-Based Adjustments
   - Heavy Read:
     * load_threshold = 0.3
     * scrub_sleep = 20
   - Heavy Write:
     * load_threshold = 0.2
     * scrub_sleep = 30
     * min_interval = 172800 (48h)
   - Mixed Use:
     * load_threshold = 0.4
     * scrub_sleep = 15
   - Archival:
     * load_threshold = 0.6
     * scrub_sleep = 10

### Architecture Decisions

1. Standalone Script
   - Single bash script for portability
   - No external dependencies
   - Cross-platform compatibility (Linux/Mac/WSL)

2. Input Validation
   - Strict number validation
   - Zero-value handling for absent device types
   - Clear error messages

3. Output Format
   - Color-coded sections
   - Clear command examples
   - Backup instructions
   - Implementation recommendations

4. Error Handling
   - Input validation with helpful messages
   - Division by zero protection
   - Workload type validation

### Performance Considerations

1. Calculation Efficiency
   - Simple arithmetic operations
   - No external process calls
   - Minimal memory usage

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

2. Improvements
   - Additional workload profiles
   - More granular PG distribution analysis
   - Machine learning for parameter optimization
   - Integration with monitoring systems

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
