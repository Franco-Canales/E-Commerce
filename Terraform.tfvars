 ============================================================================
 E-commerce Project - Terraform Variables Configuration (FIXED)
 Environment: Production (Educational)
# Role: LabRole
# Region: us-east-1
# ============================================================================

# Configuración básica del proyecto
project_name = "ecommerce"
environment  = "production"

# Key Pair (se creará automáticamente)
key_pair_name = "ecommerce-production-key"

# Configuración de Auto Scaling (optimizada para proyecto educativo)
min_instances     = 2  # Mínimo para alta disponibilidad
max_instances     = 4  # Máximo para demostrar auto scaling
desired_instances = 2  # Comenzar con 2 instancias

# Configuración de seguridad (abierta para simplicidad educativa)
allowed_cidr_blocks = ["0.0.0.0/0"]

# FIXED: Variable ahora declarada correctamente en despliege.tf
enable_waf = false  # Deshabilitado para simplicidad en labs

# ============================================================================
# NOTAS PARA EL PROYECTO EDUCATIVO:
# ============================================================================
# 
# CORRECCIONES APLICADAS:
# - Variable 'enable_waf' ahora está correctamente declarada
# - Eliminados conflictos de tags que causaban errores de plan inconsistente
# - Optimizada configuración del provider AWS para entornos de laboratorio
#
# 1. Esta configuración está optimizada para:
#    - Demostrar conceptos de infraestructura como código
#    - Mostrar alta disponibilidad con múltiples AZ
#    - Exhibir auto scaling automático
#    - Minimizar costos manteniendo funcionalidad completa
#
# 2. Recursos que se crearán:
#    - 1 VPC con subnets públicas y privadas
#    - 2-4 instancias EC2 t3.micro (auto scaling)
#    - 1 Application Load Balancer
#    - 1 base de datos RDS MySQL (db.t3.micro)
#    - 1 NAT Gateway (optimización de costos)
#    - CloudWatch para monitoreo
#    - S3 bucket para contenido estático
#    - Secrets Manager para credenciales
#
# 3. Estimación de costos mensuales (aproximado):
#    - 2x t3.micro instances: ~$17/mes
#    - 1x NAT Gateway: ~$45/mes
#    - 1x db.t3.micro: ~$15/mes  
#    - 1x ALB: ~$25/mes
#    - S3/CloudWatch: ~$5/mes
#    - Total aproximado: ~$107/mes
#
# 4. Tiempo estimado de despliegue: 15-20 minutos
#
# 5. Para destruir recursos: terraform destroy
#
# ============================================================================
