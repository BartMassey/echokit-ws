idf_component_register(
     SRCS 
          "./xl9555.c" 
          "./myiic.c"
          "./es8311.c"
          "./lcd.c"

     INCLUDE_DIRS 
          "." 

     REQUIRES driver esp_lcd log freertos
)

# target_compile_options(${COMPONENT_LIB} PRIVATE -DCONFIG_I2C_SKIP_LEGACY_CONFLICT_CHECK)